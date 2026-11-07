// Il correttore, al posto di Grammarly. Quando smetti di scrivere per un attimo controlla il paragrafo in cui sei:
// l'ortografia subito, con il correttore di macOS (in italiano e in inglese insieme: "deploy" o "meeting" in una frase
// italiana non sono errori); la grammatica, le concordanze e la punteggiatura con Apple Intelligence, una frase alla
// volta e solo quando la frase è finita (ci mette uno-tre secondi: mai mentre scrivi), con il risultato tenuto in
// memoria. Gli errori si sottolineano sotto la parola (rosso l'ortografia, blu la grammatica) dove l'app dice dov'è il
// testo; la scorciatoia (predefinita ⌃⌥G) apre un pannello con le correzioni: Invio le applica tutte. Con del testo
// selezionato la scorciatoia corregge la selezione nel pannello Riscrivi. Tutto sul Mac; niente testo nel registro.

import AppKit
import NaturalLanguage
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class Proofreader: NSObject, ObservableObject, NSWindowDelegate {
    struct Issue: Identifiable, Equatable {
        enum Kind { case spelling, grammar }
        let id = UUID()
        let kind: Kind
        /// La modifica, con la posizione relativa all'inizio del paragrafo controllato.
        let edit: TextEdit

        static func == (a: Issue, b: Issue) -> Bool { a.kind == b.kind && a.edit == b.edit }
    }

    @Published private(set) var issues: [Issue] = []
    /// Vero mentre Apple Intelligence controlla una frase (per il pannello).
    @Published private(set) var checking = false

    /// Con del testo selezionato la scorciatoia corregge la selezione (AppModel: Riscrivi › Correggi).
    var onProofreadSelection: (() -> Void)?

    private let prefs: Preferences
    private let overlay = UnderlineOverlay()
    private var idleTask: Task<Void, Never>?
    private var grammarTask: Task<Void, Never>?
    /// Il paragrafo controllato: il campo, dove comincia (UTF-16) e il testo.
    private var target: (element: AXUIElement, pid: pid_t, start: Int, text: String)?
    /// Frase → frase corretta, per non chiedere due volte ad Apple Intelligence la stessa frase.
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private var panel: NSPanel?

    /// Per la diagnostica: solo conteggi e tempi.
    private(set) var checks = 0
    private(set) var grammarChecks = 0
    private(set) var lastGrammarMs: Int?
    private(set) var applied = 0

    init(prefs: Preferences) {
        self.prefs = prefs
        super.init()
        SpellGuard.learned = Set(prefs.learnedWords.map { $0.lowercased() })
    }

    /// Carica il modello di Apple Intelligence in anticipo: la prima frase si controlla in un secondo invece che in nove.
    func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), prefs.proofreading, prefs.grammarCheck, AppleEngine.unavailableReason == nil {
            LanguageModelSession(instructions: Self.instructions).prewarm()
        }
        #endif
    }

    // MARK: - Quando controllare

    /// A ogni tasto: le sottolineature spariscono (il testo si sposta) e il controllo riparte dopo una pausa.
    func textChanged() {
        idleTask?.cancel()
        grammarTask?.cancel()
        grammarTask = nil
        checking = false
        if !issues.isEmpty { issues = [] }
        overlay.hide()
        guard prefs.enabled, prefs.proofreading else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.check(askModel: true)
        }
    }

    /// Cambio di app o clic: via tutto.
    func reset() {
        idleTask?.cancel()
        grammarTask?.cancel()
        grammarTask = nil
        checking = false
        issues = []
        target = nil
        overlay.hide()
    }

    // MARK: - Controllo

    /// Controlla il paragrafo prima del cursore. L'ortografia e le frasi già corrette in passato subito; le frasi finite
    /// e non ancora viste con Apple Intelligence (al più due per volta), se `askModel`.
    private func check(askModel: Bool) {
        guard prefs.enabled, prefs.proofreading, !KeyMonitor.secureInputActive,
              let field = FocusReader.focusedField(), !field.isSecure, field.selection.length == 0,
              field.pid != getpid(), !prefs.isExcluded(field.bundleID),
              let before = FocusReader.text(before: field, max: 1000) else { return }
        var paragraph = before
        if let newline = paragraph.lastIndex(where: { $0.isNewline }) {
            paragraph = String(paragraph[paragraph.index(after: newline)...])
        }
        guard paragraph.split(whereSeparator: { $0.isWhitespace }).count >= 3 else { return }
        let start = field.caret - paragraph.utf16.count
        guard start >= 0 else { return }
        checks += 1
        target = (field.element, field.pid, start, paragraph)
        let language = LanguageGuess.code(for: paragraph)
        let sentences = Self.sentences(paragraph)
        var pending: [(range: NSRange, text: String)] = []
        for sentence in sentences {
            if cache[sentence.text] == nil, sentence.finished { pending.append((sentence.range, sentence.text)) }
        }
        show(collect(paragraph, sentences: sentences, language: language), field: field)
        guard askModel, prefs.grammarCheck, !pending.isEmpty, AppleEngine.unavailableReason == nil else { return }
        let element = field.element
        checking = true
        grammarTask = Task { [weak self] in
            for sentence in pending.suffix(2) {
                let began = Date()
                let corrected = try? await Self.correct(sentence.text, language: language)
                guard !Task.isCancelled, let self else { return }
                self.grammarChecks += 1
                self.lastGrammarMs = Int(Date().timeIntervalSince(began) * 1000)
                self.remember(sentence.text, corrected: corrected ?? sentence.text)
            }
            guard !Task.isCancelled, let self else { return }
            self.checking = false
            // Il campo e il paragrafo sono ancora quelli: si mostrano anche gli errori di grammatica.
            if let now = FocusReader.focusedField(), CFEqual(now.element, element),
               let text = FocusReader.text(before: now, max: 1000), text.hasSuffix(paragraph) {
                self.show(self.collect(paragraph, sentences: sentences, language: language), field: now)
            }
        }
    }

    /// Gli errori del paragrafo: la grammatica delle frasi già controllate, poi l'ortografia dove la grammatica non ha
    /// già detto niente. L'ultima parola senza spazio dopo è ancora in scrittura: non si guarda.
    private func collect(_ paragraph: String, sentences: [Sentence], language: String?) -> [Issue] {
        var out: [Issue] = []
        for sentence in sentences {
            guard let corrected = cache[sentence.text] else { continue }
            for edit in TextDiff.edits(from: sentence.text, to: corrected) {
                var shifted = edit
                shifted.range.location += sentence.range.location
                out.append(Issue(kind: .grammar, edit: shifted))
            }
        }
        let text = paragraph as NSString
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = paragraph
        let stillTyping = paragraph.last.map { $0.isLetter } ?? false
        tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
            let nsRange = NSRange(range, in: paragraph)
            if stillTyping, NSMaxRange(nsRange) == text.length { return true }
            if out.contains(where: { NSIntersectionRange($0.edit.range, nsRange).length > 0 }) { return true }
            let word = String(paragraph[range])
            guard !SpellGuard.isKnown(word), let guess = SpellGuard.guesses(word, language: language).first else { return true }
            out.append(Issue(kind: .spelling, edit: TextEdit(range: nsRange, original: word, replacement: guess)))
            return true
        }
        return out.sorted { $0.edit.range.location < $1.edit.range.location }
    }

    private func show(_ found: [Issue], field: FocusedField) {
        issues = found
        guard let target, !found.isEmpty else { overlay.hide(); return }
        let marks: [UnderlineOverlay.Mark] = found.compactMap { issue in
            let range = CFRange(location: target.start + issue.edit.range.location, length: issue.edit.range.length)
            guard let rect = FocusReader.rect(for: range, in: field) else { return nil }
            return UnderlineOverlay.Mark(rect: rect, grammar: issue.kind == .grammar)
        }
        overlay.show(marks)
    }

    private func remember(_ sentence: String, corrected: String) {
        if cache[sentence] == nil { cacheOrder.append(sentence) }
        cache[sentence] = corrected
        if cacheOrder.count > 300 {
            let old = cacheOrder.removeFirst()
            cache[old] = nil
        }
    }

    // MARK: - Frasi

    struct Sentence {
        let range: NSRange
        let text: String
        /// Finisce con un punto, un punto esclamativo o interrogativo (o un a capo): si può controllare la grammatica.
        let finished: Bool
    }

    static func sentences(_ paragraph: String) -> [Sentence] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = paragraph
        var out: [Sentence] = []
        tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
            var text = String(paragraph[range])
            var nsRange = NSRange(range, in: paragraph)
            // Senza gli spazi finali: la frase corretta non li ha.
            while let last = text.last, last.isWhitespace {
                text.removeLast()
                nsRange.length -= last.utf16.count
            }
            let finished = text.last.map { ".!?…".contains($0) } ?? false
            if text.split(whereSeparator: { $0.isWhitespace }).count >= 3 {
                out.append(Sentence(range: nsRange, text: text, finished: finished))
            }
            return true
        }
        return out
    }

    // MARK: - Apple Intelligence

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Generable
    struct Correction {
        @Guide(description: "The sentence with only its mistakes fixed; identical to the input if it has no mistakes")
        var corrected: String
    }
    #endif

    static let instructions = """
        You are a careful proofreader. Fix only real mistakes in spelling, grammar, agreement, accents, apostrophes and \
        punctuation. Do not change the style, the word choice, the tone or the meaning, and do not rephrase. The text may \
        mix Italian and English: keep English words used in Italian (technical terms, brand names, modern anglicisms such \
        as meeting, deadline, feedback, deploy) exactly as they are, and never translate. Keep names, numbers and \
        formatting. If the sentence has no mistakes, return it unchanged.
        """

    /// La frase corretta da Apple Intelligence. Lancia un errore se il modello non c'è o non risponde.
    static func correct(_ sentence: String, language: String?) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(samplingMode: .greedy, temperature: nil, maximumResponseTokens: 400)
            let response = try await session.respond(to: sentence, generating: Correction.self, options: options)
            let corrected = response.content.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            return corrected.isEmpty ? sentence : corrected
        }
        #endif
        throw EngineError(AppleEngine.unavailableReason ?? L("Apple Intelligence non è disponibile adesso."))
    }

    // MARK: - Pannello

    /// Dalla scorciatoia: con una selezione la si corregge in Riscrivi; altrimenti si controlla subito il paragrafo
    /// (aspettando Apple Intelligence per le frasi non ancora viste) e si apre il pannello delle correzioni.
    func trigger() {
        if let field = FocusReader.focusedField(), field.selection.length > 0 {
            onProofreadSelection?()
            return
        }
        idleTask?.cancel()
        let caret = FocusReader.focusedField().flatMap { FocusReader.caretBounds($0, afterNewline: false) }
        // Anche le frasi non finite: chi preme la scorciatoia vuole il controllo adesso.
        checkNow()
        showPanel(near: caret)
        diag(.app, "proofread panel opened")
    }

    private func checkNow() {
        guard let field = FocusReader.focusedField(), !field.isSecure,
              let before = FocusReader.text(before: field, max: 1000) else { return }
        var paragraph = before
        if let newline = paragraph.lastIndex(where: { $0.isNewline }) {
            paragraph = String(paragraph[paragraph.index(after: newline)...])
        }
        let start = field.caret - paragraph.utf16.count
        guard start >= 0, !paragraph.trimmingCharacters(in: .whitespaces).isEmpty else { issues = []; return }
        target = (field.element, field.pid, start, paragraph)
        let language = LanguageGuess.code(for: paragraph)
        // Anche l'ultima frase non finita conta come finita.
        let sentences = Self.sentences(paragraph).map { Sentence(range: $0.range, text: $0.text, finished: true) }
        issues = collect(paragraph, sentences: sentences, language: language)
        let pending = sentences.filter { cache[$0.text] == nil }
        guard prefs.grammarCheck, !pending.isEmpty, AppleEngine.unavailableReason == nil else { return }
        checking = true
        grammarTask?.cancel()
        grammarTask = Task { [weak self] in
            for sentence in pending.suffix(3) {
                let began = Date()
                let corrected = try? await Self.correct(sentence.text, language: language)
                guard !Task.isCancelled, let self else { return }
                self.grammarChecks += 1
                self.lastGrammarMs = Int(Date().timeIntervalSince(began) * 1000)
                self.remember(sentence.text, corrected: corrected ?? sentence.text)
                self.issues = self.collect(paragraph, sentences: sentences, language: language)
            }
            self?.checking = false
        }
    }

    /// Applica le correzioni scelte: via Accessibilità se l'app lo permette (il cursore torna in fondo), altrimenti
    /// cancellando dal primo errore al cursore e riscrivendo il pezzo corretto. Solo se il paragrafo è ancora quello.
    func apply(_ chosen: [Issue]) {
        guard let target, !chosen.isEmpty else { return }
        let pid = target.pid
        let element = target.element
        closePanel()
        if let app = NSRunningApplication(processIdentifier: pid) { app.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            guard let field = FocusReader.focusedField(), CFEqual(field.element, element),
                  let before = FocusReader.text(before: field, max: 1000), before.hasSuffix(target.text),
                  field.caret - target.text.utf16.count == target.start else {
                diag(.app, "proofread not applied: text changed")
                return
            }
            let edits = chosen.map(\.edit).sorted { $0.range.location < $1.range.location }
            if !self.applyViaAccessibility(edits, field: field, start: target.start, length: target.text.utf16.count) {
                let first = edits[0].range.location
                let tail = (target.text as NSString).substring(from: first)
                let shifted = edits.map { edit -> TextEdit in
                    var e = edit
                    e.range.location -= first
                    return e
                }
                TextInserter.deleteBackward(tail.count)
                TextInserter.type(TextDiff.apply(shifted, to: tail))
            }
            self.applied += chosen.count
            self.issues.removeAll { issue in chosen.contains(issue) }
            self.overlay.hide()
            diag(.app, "proofread applied \(chosen.count)")
        }
    }

    private func applyViaAccessibility(_ edits: [TextEdit], field: FocusedField, start: Int, length: Int) -> Bool {
        guard field.markerText == nil else { return false }
        var delta = 0
        for (index, edit) in edits.reversed().enumerated() {
            let range = CFRange(location: start + edit.range.location, length: edit.range.length)
            guard FocusReader.select(field, range: range), FocusReader.replaceSelection(field, with: edit.replacement) else {
                // Se la prima non va si passa alla tastiera; se ne è già andata qualcuna non si può più: ci si ferma.
                if index == 0 { FocusReader.select(field, range: CFRange(location: start + length, length: 0)) }
                return index > 0
            }
            delta += edit.replacement.utf16.count - edit.range.length
        }
        FocusReader.select(field, range: CFRange(location: start + length + delta, length: 0))
        return true
    }

    /// "Ignora": la parola non si segnala più (resta nelle preferenze, sul Mac).
    func ignore(_ issue: Issue) {
        issues.removeAll { $0 == issue }
        guard issue.kind == .spelling else { return }
        let word = issue.edit.original.lowercased()
        if !prefs.learnedWords.contains(word) { prefs.learnedWords.append(word) }
        SpellGuard.learned.insert(word)
    }

    private func showPanel(near caret: CGRect?) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: ProofreadView.size),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: false)
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.isFloatingPanel = true
            p.level = .floating
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: ProofreadView(proofreader: self))
            p.delegate = self
            panel = p
        }
        guard let panel else { return }
        panel.title = L("Correggi")
        PanelPlacement.place(panel, size: ProofreadView.size, near: caret)
        panel.makeKeyAndOrderFront(nil)
    }

    func closePanel() {
        panel?.orderOut(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {}
}

/// Dove mettere un pannello: sotto il rettangolo (coordinate AX), o sopra se sotto non c'è posto; al centro se non si sa.
enum PanelPlacement {
    @MainActor
    static func place(_ panel: NSPanel, size: CGSize, near rect: CGRect?) {
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
    }
}

struct ProofreadView: View {
    static let size = CGSize(width: 420, height: 320)

    @ObservedObject var proofreader: Proofreader

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Correggi")).font(.headline)
                Spacer()
                if proofreader.checking {
                    ProgressView().controlSize(.small)
                    Text(L("Controllo la grammatica…")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
            if proofreader.issues.isEmpty {
                Text(proofreader.checking ? L("Sto controllando il paragrafo.") : L("Nessun errore nel paragrafo."))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(proofreader.issues) { issue in row(issue) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Text(L("Invio applica tutto, Esc chiude.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Chiudi")) { proofreader.closePanel() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Applica tutto")) { proofreader.apply(proofreader.issues) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(proofreader.issues.isEmpty)
            }
        }
        .padding(16)
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func row(_ issue: Proofreader.Issue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: issue.kind == .grammar ? "text.badge.checkmark" : "character.cursor.ibeam")
                .foregroundStyle(issue.kind == .grammar ? Color.blue : Color.red)
                .accessibilityLabel(issue.kind == .grammar ? L("Grammatica") : L("Ortografia"))
            Text(issue.edit.original).strikethrough().foregroundStyle(.secondary)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            Text(issue.edit.replacement).fontWeight(.semibold)
            Spacer()
            Button(L("Applica")) { proofreader.apply([issue]) }.controlSize(.small)
            if issue.kind == .spelling {
                Button(L("Ignora")) { proofreader.ignore(issue) }.controlSize(.small)
            }
        }
    }
}
