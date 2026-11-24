// Riscrivi la selezione: scorciatoia (predefinita ⌃⌥R) sul testo selezionato in qualunque app. Un pannello piccolo
// vicino alla selezione, che non attiva Type_w/Me: più breve, più formale, più informale, correggi, o un'istruzione
// scritta da te; anteprima; "Sostituisci" scrive al posto della selezione (via Accessibilità, altrimenti incollando).
// Il modello è quello dei suggerimenti (Gemma o Apple Intelligence, Completer.activeEngine).

import AppKit
import SwiftUI

@MainActor
final class RewriteController: NSObject, ObservableObject, NSWindowDelegate {
    enum State: Equatable {
        case idle, working, done(String), failed(String)
    }

    @Published var state: State = .idle
    @Published var original = ""
    @Published var instruction = ""

    let prefs: Preferences
    /// Il motore lo sceglie il Completer (activeEngine): lo stesso dei suggerimenti.
    private let completer: Completer
    private var field: FocusedField?
    private var panel: NSPanel?
    private var task: Task<Void, Never>?

    init(prefs: Preferences, completer: Completer) {
        self.prefs = prefs
        self.completer = completer
        super.init()
    }

    /// Dalla scorciatoia o dal menu: legge la selezione e apre il pannello.
    func trigger() {
        let field = FocusReader.focusedField()
        self.field = field
        original = field.flatMap { FocusReader.selectedText($0) } ?? ""
        state = .idle
        task?.cancel()
        completer.ignoreOwnProcess = true
        showPanel(near: field.flatMap { FocusReader.selectionBounds($0) })
        diag(.app, original.isEmpty ? "rewrite opened without selection" : "rewrite opened")
    }

    func run(_ preset: RewritePreset) { run(instruction: preset.instruction) }

    func runCustom() {
        let own = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !own.isEmpty else { return }
        run(instruction: "Follow this instruction from the user about the text: \(own)")
    }

    private func run(instruction: String) {
        guard !original.isEmpty else { return }
        guard let engine = completer.activeEngine(forRewrite: true) else {
            state = .failed(L("Nessun modello istruito disponibile: per riscrivere serve Apple Intelligence o un Gemma istruito (Impostazioni › Motori)."))
            return
        }
        if let why = engine.unavailableReason { state = .failed(why); return }
        task?.cancel()
        state = .working
        let text = original
        let language = LanguageGuess.code(for: text)
        task = Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await engine.rewrite(text, instruction: instruction, language: language)) } catch { result = .failure(error) }
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let raw):
                let clean = Prompting.cleanRewrite(raw)
                self.state = clean.isEmpty ? .failed(L("Il modello non ha risposto.")) : .done(clean)
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
                diag(.engine, "rewrite failed: \(error.localizedDescription)")
            }
        }
    }

    var result: String? {
        if case .done(let text) = state { return text }
        return nil
    }

    func replace() {
        guard let text = result else { return }
        let field = field
        closePanel()
        if let field, let app = NSRunningApplication(processIdentifier: field.pid) { app.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let field, let now = FocusReader.focusedField(), CFEqual(now.element, field.element), now.selection.length > 0,
               FocusReader.replaceSelection(now, with: text) { return }
            TextInserter.paste(text)
        }
        diag(.app, "rewrite replaced")
    }

    func copyResult() {
        guard let text = result else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Pannello

    private func showPanel(near rect: CGRect?) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: RewriteView.size),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: false)
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.isFloatingPanel = true
            p.level = .floating
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = false
            p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: RewriteView(controller: self))
            p.delegate = self
            panel = p
        }
        guard let panel else { return }
        panel.title = L("Riscrivi la selezione")
        let size = RewriteView.size
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let screen = rect.flatMap { r in NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: r.midX, y: screenHeight - r.midY)) }) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin: CGPoint
        if let rect {
            origin = CGPoint(x: rect.minX, y: screenHeight - rect.maxY - size.height - 10)
            if origin.y < visible.minY { origin.y = screenHeight - rect.minY + 10 }
        } else {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
        origin.y = min(max(visible.minY + 8, origin.y), visible.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func closePanel() {
        panel?.orderOut(nil)
        task?.cancel()
        completer.ignoreOwnProcess = false
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.task?.cancel()
                self?.completer.ignoreOwnProcess = false
            }
        }
    }
}

struct RewriteView: View {
    static let size = CGSize(width: 540, height: 380)

    @ObservedObject var controller: RewriteController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Riscrivi la selezione"))
                .font(SG.Font.instruction)
                .padding(.top, 6)
            if controller.original.isEmpty {
                Text(L("Seleziona del testo in un'app, poi premi di nuovo %@.", controller.prefs.rewrite.display))
                    .foregroundStyle(SG.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else {
                ScrollView {
                    Text(controller.original)
                        .font(SG.Font.field)
                        .foregroundStyle(SG.Ink.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 64)
                .contentCard(padding: 8)
                HStack(spacing: 6) {
                    ForEach(RewritePreset.allCases) { preset in
                        Button { controller.run(preset) } label: { Label(preset.title, systemImage: preset.symbol).lineLimit(1).fixedSize() }
                            .buttonStyle(.sgSecondary)
                    }
                }
                HStack {
                    TextField(L("Oppure dì tu cosa fare, per esempio: traduci in inglese"), text: $controller.instruction)
                        .sgField()
                        .onSubmit { controller.runCustom() }
                    Button(L("Vai")) { controller.runCustom() }
                        .buttonStyle(.sgSecondary)
                        .disabled(controller.instruction.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                resultArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            HStack {
                Button(L("Copia")) { controller.copyResult() }
                    .buttonStyle(.sgSecondary)
                    .disabled(controller.result == nil)
                Spacer()
                Button(L("Chiudi")) { controller.closePanel() }
                    .buttonStyle(.sgSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("Sostituisci")) { controller.replace() }
                    .buttonStyle(.sgPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.result == nil)
            }
        }
        .padding(16)
        .frame(width: Self.size.width, height: Self.size.height)
        .sguardoAccent(default: .typewithme)
    }

    @ViewBuilder
    private var resultArea: some View {
        switch controller.state {
        case .idle:
            Text(L("Scegli come riscrivere.")).foregroundStyle(SG.Ink.secondary)
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Sto riscrivendo…")).foregroundStyle(SG.Ink.secondary)
            }
        case .done(let text):
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentCard(padding: 8)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
