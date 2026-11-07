// Sinonimi della parola selezionata: scorciatoia (predefinita ⌃⌥S) su una parola o un'espressione breve in qualunque
// app. Un pannello piccolo vicino alla selezione con le alternative numerate: subito quelle vicine nel vocabolario di
// macOS (NLEmbedding, sul Mac), poi quelle di Apple Intelligence, che guarda la frase e tiene genere, numero e tempo.
// Un numero o un clic sostituisce la selezione (via Accessibilità, altrimenti scrivendo al suo posto).

import AppKit
import NaturalLanguage
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class SynonymsController: NSObject, ObservableObject {
    @Published private(set) var word = ""
    @Published private(set) var options: [String] = []
    @Published private(set) var working = false
    @Published private(set) var message: String?

    private var field: FocusedField?
    private var panel: NSPanel?
    private var task: Task<Void, Never>?
    private let completer: Completer

    init(completer: Completer) {
        self.completer = completer
        super.init()
    }

    func trigger() {
        task?.cancel()
        let field = FocusReader.focusedField()
        self.field = field
        let selected = field.flatMap { FocusReader.selectedText($0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        word = selected
        options = []
        message = nil
        guard !selected.isEmpty, selected.split(whereSeparator: { $0.isWhitespace }).count <= 4 else {
            message = selected.isEmpty ? L("Seleziona una parola, poi premi di nuovo la scorciatoia.")
                                       : L("Seleziona una parola o un'espressione breve.")
            showPanel(near: field.flatMap { FocusReader.selectionBounds($0) })
            return
        }
        let language = LanguageGuess.code(for: contextSentence(field) ?? selected) ?? "it"
        options = Self.nearby(selected, language: language)
        completer.ignoreOwnProcess = true
        showPanel(near: field.flatMap { FocusReader.selectionBounds($0) })
        guard AppleEngine.unavailableReason == nil else { return }
        working = true
        let sentence = contextSentence(field)
        task = Task { [weak self] in
            let found = (try? await Self.ask(selected, sentence: sentence)) ?? []
            guard !Task.isCancelled, let self else { return }
            self.working = false
            // Prima quelle di Apple Intelligence (guardano la frase), poi le altre, senza doppioni.
            var merged: [String] = []
            for option in found + self.options where !merged.contains(where: { $0.caseInsensitiveCompare(option) == .orderedSame })
                && option.caseInsensitiveCompare(selected) != .orderedSame {
                merged.append(option)
            }
            self.options = Array(merged.prefix(9))
        }
        diag(.app, "synonyms opened")
    }

    /// La frase intorno alla selezione (per Apple Intelligence), se l'app la dà.
    private func contextSentence(_ field: FocusedField?) -> String? {
        guard let field else { return nil }
        let before = FocusReader.text(before: field, max: 200) ?? ""
        let after = FocusReader.text(after: field, max: 200) ?? ""
        let text = before + "[[" + word + "]]" + after
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Le parole vicine nel vocabolario di macOS: subito, anche senza Apple Intelligence. Solo per una parola sola.
    static func nearby(_ word: String, language: String) -> [String] {
        guard !word.contains(" ") else { return [] }
        let lang = NLLanguage(rawValue: language)
        guard let embedding = NLEmbedding.wordEmbedding(for: lang) ?? NLEmbedding.wordEmbedding(for: .italian) else { return [] }
        let lower = word.lowercased()
        let capitalized = word.first?.isUppercase == true
        return embedding.neighbors(for: lower, maximumCount: 8).map(\.0)
            .filter { !$0.contains(lower) && !lower.contains($0) }
            .prefix(6)
            .map { capitalized ? $0.prefix(1).uppercased() + $0.dropFirst() : $0 }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Generable
    struct Alternatives {
        @Guide(description: "Up to six synonyms or close alternatives that fit the sentence", .count(1...6))
        var words: [String]
    }
    #endif

    static func ask(_ word: String, sentence: String?) async throws -> [String] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: """
                You suggest synonyms. Give alternatives for the selected word or expression that fit the sentence, in the \
                same language, with the same grammatical form (gender, number, tense, person) and the same capitalization. \
                Prefer natural, common alternatives first. Words or short expressions only, no explanations.
                """)
            var prompt = "Selected: \(word)"
            if let sentence { prompt += "\nSentence (the selection is between [[ ]]): \(sentence)" }
            let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 120)
            let response = try await session.respond(to: prompt, generating: Alternatives.self, options: options)
            return response.content.words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        #endif
        return []
    }

    func choose(_ option: String) {
        let field = field
        closePanel()
        if let field, let app = NSRunningApplication(processIdentifier: field.pid) { app.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let field, let now = FocusReader.focusedField(), CFEqual(now.element, field.element), now.selection.length > 0,
               FocusReader.replaceSelection(now, with: option) { return }
            TextInserter.type(option)   // la selezione è ancora lì: scrivere la sostituisce
        }
        diag(.app, "synonym chosen")
    }

    private func showPanel(near rect: CGRect?) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: SynonymsView.size),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: false)
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.isFloatingPanel = true
            p.level = .floating
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: SynonymsView(controller: self))
            panel = p
        }
        guard let panel else { return }
        panel.title = L("Sinonimi")
        PanelPlacement.place(panel, size: SynonymsView.size, near: rect)
        panel.makeKeyAndOrderFront(nil)
    }

    func closePanel() {
        panel?.orderOut(nil)
        task?.cancel()
        working = false
        completer.ignoreOwnProcess = false
    }
}

struct SynonymsView: View {
    static let size = CGSize(width: 300, height: 300)

    @ObservedObject var controller: SynonymsController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(controller.word.isEmpty ? L("Sinonimi") : controller.word).font(.headline).lineLimit(1)
                Spacer()
                if controller.working { ProgressView().controlSize(.small) }
            }
            .padding(.top, 6)
            if let message = controller.message {
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if controller.options.isEmpty {
                Text(controller.working ? L("Cerco alternative adatte alla frase…") : L("Nessuna alternativa trovata."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(controller.options.enumerated()), id: \.offset) { index, option in
                    Button { controller.choose(option) } label: {
                        HStack {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 14)
                            Text(option)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
                }
            }
            Spacer()
            HStack {
                Text(L("Un numero sceglie, Esc chiude.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Chiudi")) { controller.closePanel() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: Self.size.width, height: Self.size.height)
    }
}
