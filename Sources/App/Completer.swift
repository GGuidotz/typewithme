// Il cuore dell'app: ascolta i tasti, aspetta che ti fermi, legge il campo, chiede un seguito (prima alla memoria e
// alle regole, poi al modello) e lo mostra in grigio, già mentre il modello lo scrive. Tab accetta una parola,
// Maiusc-Tab tutto, Esc scarta; se scrivi proprio quello che era suggerito il suggerimento avanza, se scrivi altro
// sparisce. A fine parola espande le abbreviazioni e applica le correzioni italiane. Il motore lo sceglie
// activeEngine(): Gemma se c'è (e intanto che si avvia Apple Intelligence), Apple Intelligence, o solo regole.
// Tutto sul main actor; il modello lavora in un Task che si annulla appena riprendi a scrivere.

import AppKit
import Combine

@MainActor
final class Completer: ObservableObject {
    enum Status: Equatable {
        case off, noPermission, secureInput, excluded(String), ready, thinking, suggesting

        /// Una frase per il menu e le impostazioni.
        var title: String {
            switch self {
            case .off: L("In pausa")
            case .noPermission: L("Serve il permesso Accessibilità")
            case .secureInput: L("Input sicuro attivo: niente suggerimenti")
            case .excluded(let app): L("Escluso in %@", app)
            case .ready: L("Pronto")
            case .thinking: L("Sto pensando…")
            case .suggesting: L("Suggerimento in corso")
            }
        }
    }

    struct Stats {
        var shown = 0, acceptedWords = 0, acceptedAll = 0, dismissed = 0, memoryHits = 0, corrections = 0, modelFailures = 0
        /// Suggerimenti di cui hai preso almeno una parola, e abbreviazioni espanse.
        var acceptedSuggestions = 0, expansions = 0
        /// Per app (bundle id → evento → volte): i suggerimenti mostrati e i motivi per cui non è comparso niente.
        /// Solo conteggi.
        var perApp: [String: [String: Int]] = [:]
        /// Come sono finite le risposte di un modello base (motivo → volte) e quante parole hanno tenuto in tutto.
        var stops: [String: Int] = [:]
        var stoppedAnswers = 0, stoppedWords = 0
        /// Seguiti partiti da una parola del modello personale.
        var personalPicks = 0
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var frontApp: (bundleID: String, name: String)?
    @Published private(set) var stats = Stats()
    @Published private(set) var lastError: String?
    /// Quanto ha messo il modello a rispondere, in secondi, nelle ultime 20 richieste.
    @Published private(set) var responseTimes: [Double] = []

    /// I tempi di una richiesta al modello, per la diagnostica: solo numeri.
    struct Latency {
        /// Lettura del campo con l'Accessibilità, in millisecondi.
        var readMs: Double
        /// Dalla richiesta al primo testo grigio sullo schermo; nil se non è comparso prima della fine.
        var firstMs: Double?
        /// Dalla richiesta alla risposta completa.
        var totalMs: Double
        /// Token di prompt elaborati e ripresi dalla cache, se il motore li dà (llama-server).
        var timings: LlamaTimings?
    }
    /// Le ultime 30 richieste andate a buon fine.
    private(set) var latencies: [Latency] = []

    let prefs: Preferences
    let apple = AppleEngine()
    let llama: LlamaServer
    let memory = PhraseMemory()
    let monitor = KeyMonitor()
    let overlay = GhostOverlay()
    private lazy var rules = RulesEngine(memory: memory)
    let screen = ScreenContext()
    let windowText = WindowText()
    /// Il contesto della finestra fermo per campo: cambia di rado, così il prompt resta nella cache di llama.cpp.
    private var frozenContext: (field: String, title: String?, text: String?, quoted: String?, date: Date)?
    /// Il modello personale (Sources/Core/PersonalModel.swift), costruito dalla cronologia di scrittura e tenuto al passo.
    private var personal = PersonalModel()
    private var personalLearned = Set<UUID>()
    let history = TypingHistory()
    /// Il campo in cui si sta scrivendo (per la cronologia) e i tuoi testi scelti per lui: restano gli stessi finché
    /// resti nel campo, così l'inizio del prompt non cambia e resta nella cache.
    private var historyField: String?
    private var ownWriting: (field: String, snippets: [String])?
    private let usageReader = OwnUsageReader()

    /// Chiamato dalla scorciatoia "Riscrivi la selezione".
    var onRewriteRequested: (() -> Void)?
    /// Vero mentre il pannello "Riscrivi" è aperto: nei nostri campi non si suggerisce.
    var ignoreOwnProcess = false

    private var field: FocusedField?
    private var context: TextContext?
    private var suggestion: Suggestion? { didSet { syncTap() } }
    /// Il testo prima del cursore quando il suggerimento è nato, e quanto ne è stato accettato: per la memoria.
    private var origin = ""
    private var acceptedSoFar = ""
    /// Del suggerimento sullo schermo hai già preso qualcosa (per contare i suggerimenti accettati una volta sola).
    private var acceptedCurrent = false
    private var debounceTask: Task<Void, Never>?
    /// Dopo un'accettazione: la fine del testo appena scritto, che deve comparire nel campo prima di chiedere il seguito
    /// (un testo lungo ci mette un po' ad arrivare all'app), e quante volte si è già riprovato.
    private var expectedTail: String?
    private var expectedRetries = 0
    private var lastAcceptAt = Date.distantPast { didSet { syncTap() } }
    /// Gli ultimi intervalli tra un tasto e l'altro (sotto il secondo), in secondi: il tuo ritmo, per la pausa.
    private var keyIntervals: [Double] = []
    private var lastKeyTime: TimeInterval?
    private var requestTask: Task<Void, Never>?
    private var generation = 0
    /// Il suggerimento sullo schermo è ancora a metà: il modello lo sta scrivendo.
    private var streaming = false
    /// Il suggerimento sullo schermo è rimasto a metà (l'hai preso prima che il modello finisse): non si impara.
    private var cutShort = false
    /// Dove sta il testo fantasma: mentre arrivano i pezzi il cursore non si muove, non serve rileggerlo.
    private var ghostCaret: CGRect?
    private var ghostFont: NSFont?
    /// Il margine sinistro della riga del cursore: il testo fantasma che non ci sta continua sotto, da lì.
    private var ghostLineStart: CGFloat?
    private var lastPartialAt = Date.distantPast
    /// Quando è partita la richiesta in corso e quando è comparso il suo primo pezzo.
    private var requestStartedAt = Date.distantPast
    private var firstPieceMs: Double?
    private var bag = Set<AnyCancellable>()

    init(prefs: Preferences) {
        self.prefs = prefs
        llama = LlamaServer(prefs: prefs)
    }

    var ownUsage: ProcessUsage? { usageReader.read() }

    // MARK: - Avvio

    func start() {
        // Una lettura Accessibilità che non risponde (un'app occupata) aspetterebbe 6 secondi, il predefinito di macOS,
        // bloccando il thread principale: mezzo secondo al massimo per tutte le nostre domande. Chi chiede meno
        // (WindowText, WebAccessibility, la domanda all'app in FocusReader) lo imposta sul suo elemento.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        monitor.onKeyDown = { [unowned self] stroke, action in self.handle(stroke, action: action) }
        monitor.onMouseDown = { [unowned self] in self.dismiss(reason: nil) }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.appChanged() }
            .store(in: &bag)
        prefs.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatus() }
            .store(in: &bag)
        // Chi guarda il Completer (menu, impostazioni) vede anche lo stato del server di Gemma.
        llama.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        // Un altro motore scelto: il server di Gemma non serve più.
        prefs.$engine.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.engineChoiceChanged() }
            .store(in: &bag)
        // Il modello pronto prima che serva: all'avvio, al risveglio del Mac e quando lo chiedi nelle impostazioni.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.preloadModel() }
            .store(in: &bag)
        prefs.$keepModelLoaded.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] on in if on { self?.preloadModel() } }
            .store(in: &bag)
        startMonitorIfPossible()
        appChanged()
        if prefs.useOllama { llama.refreshOllama() }
        preloadModel()
        if preferredKind == .apple { apple.prewarm() }
        diag(.app, "completer started, tap \(monitor.isRunning ? "on" : "off")")
    }

    /// Avvia Gemma in anticipo se deve restare pronto (e se è il motore scelto).
    private func preloadModel() {
        guard prefs.enabled, prefs.keepModelLoaded, preferredKind == .gemma, !llama.shouldSaveEnergy else { return }
        if llama.state == .stopped { llama.start() }
    }

    private func engineChoiceChanged() {
        preloadModel()
        if preferredKind != .gemma, llama.state != .stopped { llama.stop() }
        if preferredKind == .apple { apple.prewarm() }
    }

    // MARK: - Motore

    /// Il motore che la preferenza chiede adesso, senza avviare niente. nil: solo regole e memoria.
    var preferredKind: EngineKind? {
        switch prefs.engine {
        case .rulesOnly: return nil
        case .apple: return .apple
        case .gemma: return .gemma
        case .auto:
            if llama.isAvailable { return .gemma }
            return apple.unavailableReason == nil ? .apple : nil
        }
    }

    /// Il motore da usare per una richiesta. Con Gemma conta come uso del server (e lo avvia se è fermo); finché
    /// non è pronto risponde Apple Intelligence, se c'è, senza aspettare. nil: solo regole e memoria.
    func activeEngine(forRewrite: Bool = false) -> (any CompletionEngine)? {
        guard let kind = preferredKind else { return nil }
        if kind == .gemma {
            llama.noteUse()
            // Un modello base continua il testo ma non segue istruzioni: per riscrivere si passa ad Apple Intelligence.
            if let engine = llama.engine, !(forRewrite && engine.rawCompletion) { return engine }
        }
        if apple.unavailableReason == nil { return apple }
        return nil
    }

    /// Il nome del motore che risponderebbe adesso (senza avviare niente), nil se nessuno.
    var currentEngineName: String? {
        guard let kind = preferredKind else { return nil }
        if kind == .gemma {
            if let engine = llama.engine { return engine.displayName }
            if llama.state == .stopped { return llama.modelTitle }   // si avvia alla prima richiesta
        }
        return apple.unavailableReason == nil ? apple.displayName : nil
    }

    /// Una frase su Gemma quando non è ancora pronto, per il menu; nil se non c'è niente da dire.
    var engineNotice: String? {
        guard preferredKind == .gemma else { return nil }
        switch llama.state {
        case .starting: return L("Gemma: si avvia…")
        case .downloading: return L("Gemma: sto scaricando il modello…")
        case .failed: return L("Gemma non è disponibile: vedi Impostazioni › Motori.")
        case .stopped, .ready: return nil
        }
    }

    /// La riga di stato del menu: "Pronto · Gemma 3 1B".
    var statusLine: String {
        switch status {
        case .ready, .thinking, .suggesting:
            return status.title + " · " + (currentEngineName ?? L("Solo regole e memoria"))
        default:
            return status.title
        }
    }

    /// Il tempo medio di risposta del modello nelle ultime 20 richieste, in millisecondi.
    var averageResponseMs: Int? {
        guard !responseTimes.isEmpty else { return nil }
        let total = responseTimes.reduce(0, +)
        return Int((total / Double(responseTimes.count) * 1000).rounded())
    }

    private func recordResponseTime(_ seconds: TimeInterval) {
        responseTimes.append(seconds)
        if responseTimes.count > 20 { responseTimes.removeFirst(responseTimes.count - 20) }
    }

    private func recordLatency(_ latency: Latency) {
        latencies.append(latency)
        if latencies.count > 30 { latencies.removeFirst(latencies.count - 30) }
    }

    /// Le mediane delle ultime richieste, in inglese, per il report: "read 12 ms, first 180 ms, …". nil se non ce ne sono.
    var latencySummary: String? {
        guard !latencies.isEmpty else { return nil }
        func median(_ values: [Double]) -> Int? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return Int(sorted[sorted.count / 2].rounded())
        }
        var parts: [String] = []
        if let read = median(latencies.map(\.readMs)) { parts.append("read \(read) ms") }
        if let first = median(latencies.compactMap(\.firstMs)) { parts.append("first text \(first) ms") }
        if let total = median(latencies.map(\.totalMs)) { parts.append("complete \(total) ms") }
        let timings = latencies.compactMap(\.timings)
        if let prompt = median(timings.map { Double($0.promptTokens) }),
           let promptMs = median(timings.map(\.promptMs)) {
            parts.append("prompt \(prompt) tokens in \(promptMs) ms")
        }
        if let cached = median(timings.compactMap { $0.cachedTokens.map(Double.init) }) {
            parts.append("from cache \(cached) tokens")
        }
        let speeds = timings.filter { $0.predictedMs > 0 }.map { Double($0.predictedTokens) / $0.predictedMs * 1000 }
        if let speed = median(speeds) { parts.append("\(speed) tokens/s") }
        return parts.joined(separator: ", ") + " (median of \(latencies.count))"
    }

    /// I dati per la vista compatta (Sources/Island): stato, motore, conteggi.
    var statusInfo: TypeWithMeStatusInfo {
        var tone: TypeWithMeStatusInfo.Tone
        switch status {
        case .ready: tone = .ok
        case .thinking, .suggesting: tone = .busy
        case .off, .excluded: tone = .off
        case .noPermission, .secureInput: tone = .warning
        }
        if tone == .ok, llama.state.isBusy, preferredKind == .gemma { tone = .busy }
        return TypeWithMeStatusInfo(statusText: status.title,
                                     tone: tone,
                                     engineName: currentEngineName ?? L("Solo regole e memoria"),
                                     engineDetail: engineNotice,
                                     wordsToday: prefs.acceptedToday,
                                     wordsTotal: prefs.acceptedWordsTotal,
                                     shownThisSession: stats.shown,
                                     acceptedThisSession: stats.acceptedSuggestions,
                                     averageResponseMs: averageResponseMs)
    }

    /// Prova ad accendere il tap sulla tastiera: serve il permesso Accessibilità.
    @discardableResult
    func startMonitorIfPossible() -> Bool {
        if monitor.isRunning { refreshStatus(); return true }
        guard Permissions.accessibility else { refreshStatus(); return false }
        let ok = monitor.start()
        diag(.permissions, ok ? "key tap started" : "key tap refused")
        refreshStatus()
        return ok
    }

    func refreshStatus() {
        let new: Status
        if !prefs.enabled { new = .off }
        else if !monitor.isRunning { new = .noPermission }
        else if KeyMonitor.secureInputActive { new = .secureInput }
        else if let app = frontApp, prefs.isExcluded(app.bundleID) { new = .excluded(app.name) }
        else if suggestion != nil { new = .suggesting }
        else if requestTask != nil { new = .thinking }
        else { new = .ready }
        if new != status { status = new }
        syncTap()
    }

    /// Copia nel tap della tastiera quello che gli serve per decidere da solo, sul suo thread, se un tasto è nostro
    /// (KeyMonitor.swift, TapState).
    private func syncTap() {
        let enabled = prefs.enabled && monitor.isRunning
        let text = suggestion?.text
        let acceptWord = prefs.acceptWord, acceptAll = prefs.acceptAll, dismiss = prefs.dismiss, rewrite = prefs.rewrite
        let accepted = lastAcceptAt
        monitor.state.withLock { tap in
            tap.enabled = enabled
            tap.suggestion = text
            tap.acceptWord = acceptWord
            tap.acceptAll = acceptAll
            tap.dismiss = dismiss
            tap.rewrite = rewrite
            tap.lastAcceptAt = accepted
        }
    }

    private func appChanged() {
        frontApp = FocusReader.frontmostApp()
        // Chrome ed Electron: l'albero Accessibilità del contenuto web si accende solo se lo si chiede.
        if prefs.enabled, Permissions.accessibility, let app = NSWorkspace.shared.frontmostApplication {
            WebAccessibility.prime(app)
        }
        screen.invalidate()
        windowText.invalidate()
        frozenContext = nil
        history.endAll(recordWithoutAccepting: prefs.recordWithoutAccepting)
        historyField = nil
        ownWriting = nil
        dismiss(reason: nil)
    }

    // MARK: - Tasti

    /// Un tasto, dopo che il tap ha già deciso sul suo thread se tenerlo (`action` diverso da `.none`) o lasciarlo
    /// passare. Qui si fa il lavoro: accettare, scartare, chiedere un seguito.
    private func handle(_ s: KeyStroke, action: TapAction) {
        guard prefs.enabled, monitor.isRunning else {
            if action != .none { Self.resend(s) }
            return
        }
        switch action {
        case .rewrite:
            dismiss(reason: nil)
            onRewriteRequested?()
            return
        case .holdAfterAccept:
            return
        case .acceptWord, .acceptAll:
            // Il suggerimento c'è ancora e il fuoco è nello stesso campo? Altrimenti il tasto, che il tap ha tenuto,
            // torna all'app (succede se un tasto appena prima l'ha fatto sparire, o se il fuoco si è spostato).
            guard suggestion != nil, let field, let now = FocusReader.focusedField(), CFEqual(now.element, field.element) else {
                dismiss(reason: nil)
                Self.resend(s)
                return
            }
            // Prendi quello che c'è: se il modello stava ancora scrivendo, si ferma qui.
            stopStreaming()
            if action == .acceptWord { acceptWord() } else { acceptAll() }
            return
        case .dismiss:
            // Come per Tab: se il suggerimento era già sparito, Esc torna all'app.
            guard suggestion != nil else {
                Self.resend(s)
                return
            }
            stats.dismissed += 1
            dismiss(reason: "dismissed")
            return
        case .none:
            break
        }
        if KeyMonitor.secureInputActive {
            dismiss(reason: nil)
            return
        }
        if let suggestion {
            if s.isPrintable, !s.characters.isEmpty, suggestion.text.hasPrefix(s.characters) {
                // Stai scrivendo proprio quello che era suggerito: il suggerimento avanza.
                stopStreaming()
                acceptedSoFar += s.characters
                let rest = String(suggestion.text.dropFirst(s.characters.count))
                if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                    finishSuggestion(learn: true)
                    scheduleSuggestion()
                } else {
                    self.suggestion = Suggestion(text: rest, source: suggestion.source)
                    reposition()
                }
                return
            }
            dismiss(reason: nil)
        }
        guard !s.hasCommandOrControl else { return }
        expectedTail = nil   // scrivi tu: niente più attesa del testo accettato
        if s.isPrintable {
            noteRhythm(s.time)
            let wantsFix = prefs.italianCorrections || !prefs.abbreviations.isEmpty
            if wantsFix, Self.isBoundary(s.characters) { scheduleBoundaryFix(boundary: s.characters) }
            scheduleSuggestion()
        } else if s.isBackspace {
            scheduleSuggestion()
        }
    }

    /// Un tasto che il tap aveva tenuto ma che non era per noi: lo si riscrive, con il nostro marchio (il tap lo lascia
    /// passare).
    private static func resend(_ s: KeyStroke) {
        TextInserter.press(keyCode: CGKeyCode(s.keyCode), flags: s.flags.intersection(KeyBinding.relevantFlags))
    }

    /// L'intervallo dal tasto prima, se sei nel mezzo di una frase (sotto il secondo): gli ultimi 20 fanno il tuo ritmo.
    private func noteRhythm(_ time: TimeInterval) {
        defer { lastKeyTime = time }
        guard let last = lastKeyTime else { return }
        let gap = time - last
        guard gap > 0, gap < 1 else { return }
        keyIntervals.append(gap)
        if keyIntervals.count > 20 { keyIntervals.removeFirst(keyIntervals.count - 20) }
    }

    private static func isBoundary(_ characters: String) -> Bool {
        guard let c = characters.first, characters.count == 1 else { return false }
        return " \t.,;:!?)»\"".contains(c)
    }

    // MARK: - Suggerire

    /// Chiede un seguito dopo la pausa scelta, o dopo `delay` secondi (subito dopo un'accettazione: la cache del
    /// prompt è calda e il testo nuovo è già nel campo).
    private func scheduleSuggestion(delay override: Double? = nil) {
        debounceTask?.cancel()
        requestTask?.cancel()
        requestTask = nil
        generation += 1
        let delay = override ?? effectiveDelay
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.produceSuggestion()
        }
    }

    /// Il primo carattere visibile: i campi web mettono dopo il cursore segni invisibili (U+FFFC per gli oggetti
    /// incorporati, spazi a larghezza zero) che non sono testo dopo il cursore. nil se non ce n'è.
    private static func firstVisible(_ text: String) -> Character? {
        let invisible: Set<Unicode.Scalar> = ["\u{FFFC}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]
        return text.first { ch in
            !ch.isWhitespace && !ch.isNewline && !ch.unicodeScalars.allSatisfy { invisible.contains($0) }
        }
    }

    /// Conta un evento per app (un suggerimento mostrato, una rinuncia): in diagnostica si vede dove e perché non
    /// compare niente.
    private func tally(_ reason: String, app bundleID: String?) {
        let app = (bundleID?.isEmpty == false ? bundleID : FocusReader.frontmostApp()?.bundleID) ?? "unknown"
        stats.perApp[app, default: [:]][reason, default: 0] += 1
    }

    private func produceSuggestion() {
        guard prefs.enabled, monitor.isRunning, !KeyMonitor.secureInputActive else { return }
        let readBegan = Date()
        guard let field = FocusReader.focusedField() else { tally("no field", app: nil); return }
        guard !field.isSecure, field.selection.length == 0 else { return }
        guard !prefs.isExcluded(field.bundleID) else { return }
        if ignoreOwnProcess, field.pid == getpid() { return }
        guard let before = FocusReader.text(before: field, max: TextContext.maxBefore) else {
            tally("no text", app: field.bundleID)
            return
        }
        // Il testo appena accettato non è ancora tutto nel campo: si riprova tra poco (al più mezzo secondo).
        if let tail = expectedTail {
            if !before.hasSuffix(tail), expectedRetries < 10 {
                expectedRetries += 1
                let retries = expectedRetries
                scheduleSuggestion(delay: 0.05)
                expectedTail = tail
                expectedRetries = retries
                return
            }
            expectedTail = nil
        }
        guard before.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { return }
        var after = ""
        if prefs.midLine {
            after = FocusReader.text(after: field, max: TextContext.maxAfter) ?? ""
        } else if let next = FocusReader.text(after: field, max: 2), let visible = Self.firstVisible(next) {
            // Solo il codice dei segni che non sono lettere o cifre (un segnaposto invisibile, una parentesi): mai testo.
            let detail = visible.isLetter || visible.isNumber ? ""
                : " (" + visible.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ") + ")"
            tally("text after caret" + detail, app: field.bundleID)
            return   // c'è testo dopo il cursore e il completamento a metà riga è spento
        }
        let context = TextContext(before: before, after: after, appName: field.appName, bundleID: field.bundleID)
        guard context.endsAtWordBoundary || context.partialWord.count >= 3 else { return }
        noteHistory(before, field: field)
        // "Solo la parola corrente": a fine parola non c'è niente da completare.
        if prefs.length == .word, context.partialWord.isEmpty { return }
        let language = LanguageGuess.code(for: before)
        // La parola a metà sembra già sbagliata: allungarla non aiuta.
        if prefs.hideOnTypo, !context.partialWord.isEmpty, SpellGuard.looksMistyped(context.partialWord, language: language) {
            tally("typo", app: field.bundleID)
            return
        }
        self.field = field
        self.context = context
        generation += 1
        let gen = generation

        if let instant = rules.suggestion(for: context, useMemory: prefs.phraseMemory) {
            stats.memoryHits += 1
            show(instant, field: field, context: context)
            return
        }
        guard let engine = activeEngine() else { refreshStatus(); return }
        // Gemma: inizio del testo ancorato, così llama.cpp riusa il prompt già elaborato (Models.swift, anchored).
        let limited = engine.kind == .gemma ? context.anchored(caret: field.caret, max: engine.contextLimit)
                                            : context.limited(to: engine.contextLimit)
        // Un modello base continua un documento (Prompting.rawPrompt): il contesto della finestra entra come mail citata
        // o come chat; appunti e testi tuoi interi no, al loro posto il modello personale.
        let baseModel = (engine as? LlamaEngine)?.rawCompletion == true
        let window = windowContext(field: field, before: limited.before)
        var draft = CompletionRequest(context: limited, length: prefs.length,
                                      language: language, instructions: prefs.instructions,
                                      appInstructions: prefs.instruction(forApp: field.bundleID),
                                      clipboard: baseModel ? nil : clipboardIfAllowed(),
                                      screen: window.text,
                                      ownWriting: baseModel ? [] : ownWritingFor(field: field, before: before),
                                      wordLimit: prefs.maxWords)
        draft.windowTitle = window.title
        if baseModel {
            draft.quoted = window.quoted
            draft.personal = personalCandidates(before: before)
            draft.personalWeight = Self.personalWeight(prefs.wordChoice)
        }
        let request = draft
        let source: SuggestionSource = engine.kind == .gemma ? .gemma : .apple
        let started = Date()
        let readMs = started.timeIntervalSince(readBegan) * 1000
        requestStartedAt = started
        firstPieceMs = nil
        // I pezzi arrivano da un thread qualunque: si torna sul main actor, in ordine.
        let partial: @Sendable (String) -> Void = { [weak self] text in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.showPartial(text, request: request, generation: gen, source: source) }
            }
        }
        requestTask = Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await engine.complete(request, partial: partial)) } catch { result = .failure(error) }
            guard !Task.isCancelled, let self, self.generation == gen else { return }
            self.requestTask = nil
            switch result {
            case .success(let raw):
                let elapsed = Date().timeIntervalSince(started)
                self.recordResponseTime(elapsed)
                self.recordLatency(Latency(readMs: readMs, firstMs: self.firstPieceMs ?? elapsed * 1000, totalMs: elapsed * 1000,
                                           timings: (engine as? LlamaEngine)?.lastTimings))
                if let stop = (engine as? LlamaEngine)?.lastStop {
                    self.stats.stops[stop.reason, default: 0] += 1
                    self.stats.stoppedAnswers += 1
                    self.stats.stoppedWords += stop.words
                    if stop.personal { self.stats.personalPicks += 1 }
                    if stop.words == 0 { self.tally("model unsure", app: field.bundleID) }
                }
                self.finishStream(raw, request: request, field: field, context: context, source: source)
            case .failure(let error):
                self.stats.modelFailures += 1
                self.lastError = error.localizedDescription
                diag(.engine, "\(engine.kind.rawValue) failed: \(error.localizedDescription)")
                self.clearPartial()
                self.refreshStatus()
            }
        }
        refreshStatus()
    }

    /// Un pezzo del seguito mentre il modello scrive: il primo appare (se il cursore è ancora lì), i successivi
    /// aggiornano il testo fantasma nello stesso punto. Niente taglio a fine frase finché non è finito.
    private func showPartial(_ raw: String, request: CompletionRequest, generation gen: Int, source: SuggestionSource) {
        guard generation == gen, requestTask != nil, let field, let context else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPartialAt) >= 0.04 else { return }   // al più un aggiornamento ogni 40 ms
        guard let cleaned = Prompting.cleanCompletion(raw, for: request, final: false) else { return }
        if streaming, let current = suggestion {
            guard cleaned != current.text else { return }
            lastPartialAt = now
            suggestion = Suggestion(text: cleaned, source: source)
            overlay.show(cleaned, font: ghostFont, caret: ghostCaret, fieldFrame: field.frame, lineStartX: ghostLineStart)
            return
        }
        guard suggestion == nil else { return }
        // Il primo pezzo: il cursore è ancora lì?
        guard let current = FocusReader.focusedField(), CFEqual(current.element, field.element), current.caret == field.caret
        else { return }
        lastPartialAt = now
        show(Suggestion(text: cleaned, source: source), field: current, context: context)
        streaming = true
        firstPieceMs = now.timeIntervalSince(requestStartedAt) * 1000
    }

    /// La risposta intera: pulizia completa. Se il seguito era già sullo schermo si aggiorna lì, altrimenti appare ora.
    private func finishStream(_ raw: String, request: CompletionRequest, field: FocusedField, context: TextContext,
                              source: SuggestionSource) {
        let wasStreaming = streaming && suggestion != nil
        streaming = false
        guard let cleaned = Prompting.cleanCompletion(raw, for: request) else {
            if wasStreaming {
                suggestion = nil
                overlay.hide()
            }
            refreshStatus()
            return
        }
        if wasStreaming {
            if suggestion?.text != cleaned {
                suggestion = Suggestion(text: cleaned, source: source)
                overlay.show(cleaned, font: ghostFont, caret: ghostCaret, fieldFrame: self.field?.frame, lineStartX: ghostLineStart)
            }
            refreshStatus()
            return
        }
        // Il cursore è ancora lì?
        guard let now = FocusReader.focusedField(), CFEqual(now.element, field.element), now.caret == field.caret
        else { refreshStatus(); return }
        show(Suggestion(text: cleaned, source: source), field: now, context: context)
    }

    /// Il modello non ha finito ma è andato storto: via il pezzo mostrato.
    private func clearPartial() {
        guard streaming else { return }
        streaming = false
        suggestion = nil
        overlay.hide()
    }

    /// Hai preso (o stai scrivendo) il suggerimento a metà: il modello smette, i pezzi in arrivo non contano più.
    private func stopStreaming() {
        guard requestTask != nil || streaming else { return }
        if streaming { cutShort = true }
        requestTask?.cancel()
        requestTask = nil
        streaming = false
        generation += 1
    }

    // MARK: - Cronologia e scelta delle parole

    private static func key(for field: FocusedField) -> String { "\(field.pid)-\(CFHash(field.element))" }

    /// Il testo del campo va nella cronologia (se è accesa); cambiare campo chiude la sessione di quello prima.
    private func noteHistory(_ before: String, field: FocusedField) {
        let key = Self.key(for: field)
        if let previous = historyField, previous != key {
            history.endSession(field: previous, recordWithoutAccepting: prefs.recordWithoutAccepting)
            ownWriting = nil
        }
        historyField = key
        guard prefs.recordHistory else { return }
        history.note(before, field: key, bundleID: field.bundleID, appName: field.appName,
                     recordWithoutAccepting: prefs.recordWithoutAccepting)
    }

    /// Fino a tre tuoi testi della stessa app, scelti una volta per campo (Personalizzazione › Scelta delle parole).
    private func ownWritingFor(field: FocusedField, before: String) -> [String] {
        guard prefs.wordChoice > 0, history.count > 0 else { return [] }
        let key = Self.key(for: field)
        if let cached = ownWriting, cached.field == key, !cached.snippets.isEmpty { return cached.snippets }
        let picked = history.snippets(for: field.bundleID, before: before, count: min(3, prefs.wordChoice))
        ownWriting = (key, picked)
        return picked
    }

    /// L'app si chiude: le sessioni aperte vanno nella cronologia e si salva subito.
    func closeHistory() {
        history.endAll(recordWithoutAccepting: prefs.recordWithoutAccepting)
        history.saveNow()
    }

    /// A batteria, se la modalità batteria è accesa: pausa una volta e mezza (con una pausa fissa di 300 ms i
    /// suggerimenti sembravano lenti; il risparmio vero viene dallo schermo non letto e dal modello che si spegne).
    /// Nessuna richiesta prima del tuo ritmo: non si chiede un seguito prima di una volta e mezza il tuo intervallo
    /// tipico tra due tasti (la mediana degli ultimi 20), tra 150 e 500 ms. Con una pausa fissa più corta del ritmo di
    /// scrittura si leggeva il campo e si chiedeva un seguito a quasi ogni tasto, e il testo grigio compariva e
    /// spariva mentre scrivevi.
    private var effectiveDelay: Double {
        let delay = max(prefs.delay, rhythmDelay)
        guard prefs.batterySaver, Power.shouldSave else { return delay }
        return delay * 1.5
    }

    private var rhythmDelay: Double {
        guard keyIntervals.count >= 5 else { return 0.15 }
        let median = keyIntervals.sorted()[keyIntervals.count / 2]
        return min(0.5, max(0.15, median * 1.5))
    }

    /// Il contesto della finestra in cui scrivi: titolo e testo letti con Accessibilità (Contesto dall'app) e, se
    /// quello è poco, il testo riconosciuto sullo schermo. Resta fermo per lo stesso campo fino a 45 secondi: un
    /// prompt che cambia a ogni richiesta andrebbe rielaborato da capo.
    private func windowContext(field: FocusedField, before: String) -> (title: String?, text: String?, quoted: String?) {
        let key = Self.key(for: field)
        if let f = frozenContext, f.field == key, f.text != nil || f.quoted != nil, Date().timeIntervalSince(f.date) < 45 {
            return (f.title, f.text, f.quoted)
        }
        var title: String?
        var text: String?
        var quoted: String?
        if prefs.appContext, let snapshot = windowText.context(for: field) {
            title = snapshot.title
            text = Self.withoutTyped(snapshot.text, before: before)
        }
        if (text?.count ?? 0) < 200, let seen = screenIfAllowed(pid: field.pid, before: before), seen.count > (text?.count ?? 0) {
            text = seen
        }
        // In una risposta di Mail il messaggio a cui rispondi sta nello stesso campo, sotto il cursore.
        if prefs.appContext, Prompting.appKind(field.bundleID) == .mail,
           let below = FocusReader.text(after: field, max: 1500, wholeLines: true) {
            let trimmed = below.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { quoted = trimmed }
        }
        frozenContext = (key, title, text, quoted, Date())
        return (title, text, quoted)
    }

    /// Le parole che di solito scrivi in questo punto, secondo il modello personale. Il modello impara dalle voci nuove
    /// della cronologia (e riparte da capo se ne hai cancellate). Vuoto con "Scelta delle parole" spenta.
    private func personalCandidates(before: String) -> [PersonalCandidate] {
        guard prefs.wordChoice > 0, prefs.recordHistory else { return [] }
        if history.entries.count < personalLearned.count {
            personal = PersonalModel()
            personalLearned = []
        }
        if history.entries.count != personalLearned.count {
            for entry in history.entries where !personalLearned.contains(entry.id) {
                personal.learn(entry.text)
                personalLearned.insert(entry.id)
            }
        }
        return personal.candidates(before: before)
    }

    /// Il modello personale in numeri, per la diagnostica.
    var personalSummary: String { "\(personal.texts) texts, \(personal.vocabulary) words" }

    /// Quanto contano le tue parole rispetto a quelle di Gemma: Leggera, Media, Forte.
    static func personalWeight(_ wordChoice: Int) -> Double {
        switch wordChoice {
        case ..<1: 0
        case 1: 0.2
        case 2: 0.35
        default: 0.5
        }
    }

    /// Il testo della finestra in primo piano riconosciuto sullo schermo. nil se spento, senza permesso o a batteria
    /// con la modalità batteria.
    private func screenIfAllowed(pid: pid_t, before: String) -> String? {
        guard prefs.screenContext, !(prefs.batterySaver && Power.shouldSave) else { return nil }
        guard let text = screen.text(for: pid) else { return nil }
        return Self.withoutTyped(text, before: before)
    }

    /// Senza le righe che sono già nel testo prima del cursore (la finestra mostra anche quello che stai scrivendo).
    private static func withoutTyped(_ text: String, before: String) -> String? {
        let lines = text.split(separator: "\n").filter { line in
            line.count < 12 || !before.contains(line)
        }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        // Troppo lungo: l'inizio (l'oggetto, il titolo della pagina) e la fine (in una chat, gli ultimi messaggi).
        let half = Prompting.maxScreen / 2
        guard joined.count > Prompting.maxScreen else { return joined }
        return String(joined.prefix(half)) + "\n…\n" + String(joined.suffix(half))
    }

    private func clipboardIfAllowed() -> String? {
        guard prefs.clipboardContext, let text = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2000 else { return nil }
        return String(trimmed.prefix(500))
    }

    private func show(_ s: Suggestion, field: FocusedField, context: TextContext) {
        suggestion = s
        self.field = field
        origin = context.before
        acceptedSoFar = ""
        acceptedCurrent = false
        streaming = false
        cutShort = false
        stats.shown += 1
        let info = FocusReader.caretInfo(field, afterNewline: context.before.last?.isNewline == true)
        let caret = info.rect
        tally(caret == nil ? "no caret (\(info.source))" : "shown", app: field.bundleID)
        ghostCaret = caret
        ghostFont = caret == nil ? nil : FocusReader.font(field)
        ghostLineStart = caret == nil ? nil : FocusReader.lineStartX(field, before: context.before)
        overlay.show(s.text, font: ghostFont, caret: caret, fieldFrame: field.frame, lineStartX: ghostLineStart)
        // Il cursore c'era ma il testo grigio non si vede (niente spazio prima del bordo): si conta, per capire dove.
        if caret != nil, !overlay.isVisible { tally("ghost hidden (\(info.source))", app: field.bundleID) }
        if caret != nil, overlay.isVisible { tally("caret \(info.source)", app: field.bundleID) }
        refreshStatus()
    }

    /// Dopo un tasto o una parola accettata il cursore si è spostato: il testo fantasma lo segue.
    private func reposition(after milliseconds: Int = 40) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard let self, let s = self.suggestion, let field = FocusReader.focusedField() else { return }
            self.field = field
            let caret = FocusReader.caretBounds(field, afterNewline: false)
            self.overlay.show(s.text, font: caret == nil ? nil : FocusReader.font(field), caret: caret, fieldFrame: field.frame,
                              lineStartX: self.ghostLineStart)
        }
    }

    // MARK: - Accettare

    private func acceptWord() {
        guard let s = suggestion else { return }
        let (first, rest) = s.split()
        guard !first.isEmpty else { dismiss(reason: nil); return }
        TextInserter.type(first)
        acceptedSoFar += first
        stats.acceptedWords += 1
        noteAccepted()
        prefs.addAcceptedWords(1)
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            finishSuggestion(learn: true)
            requestAfterAccepting(first)
        } else {
            suggestion = Suggestion(text: rest, source: s.source)
            reposition(after: 80)   // il testo appena scritto deve arrivare all'app prima di rileggere il cursore
        }
    }

    private func acceptAll() {
        guard let s = suggestion else { return }
        TextInserter.type(s.text)
        acceptedSoFar += s.text
        stats.acceptedAll += 1
        noteAccepted()
        prefs.addAcceptedWords(s.words.count)
        finishSuggestion(learn: true)
        requestAfterAccepting(s.text)
    }

    /// Dopo un'accettazione il seguito dopo si chiede quasi subito: il tempo che il testo arrivi all'app, di più se è
    /// lungo; e la richiesta aspetta comunque di trovarlo nel campo (expectedTail), così non si pianta dopo un seguito
    /// lungo.
    private func requestAfterAccepting(_ typed: String) {
        lastAcceptAt = Date()
        let tail = String(typed.suffix(12))
        expectedTail = tail.trimmingCharacters(in: .whitespaces).isEmpty ? nil : tail
        expectedRetries = 0
        scheduleSuggestion(delay: 0.08 + Double(typed.utf16.count) * 0.002)
    }

    private func noteAccepted() {
        if let historyField { history.markAccepted(field: historyField) }
        guard !acceptedCurrent else { return }
        acceptedCurrent = true
        stats.acceptedSuggestions += 1
    }

    private func finishSuggestion(learn: Bool) {
        if learn, !cutShort, prefs.phraseMemory, suggestion?.source != .memory,
           TextTokens.wordCount(acceptedSoFar) >= 1 {
            memory.learn(before: origin, accepted: acceptedSoFar)
        }
        suggestion = nil
        acceptedSoFar = ""
        streaming = false
        overlay.hide()
        generation += 1
        refreshStatus()
    }

    func dismiss(reason: String?) {
        debounceTask?.cancel()
        requestTask?.cancel()
        requestTask = nil
        streaming = false
        suggestion = nil
        acceptedSoFar = ""
        overlay.hide()
        generation += 1
        refreshStatus()
    }

    // MARK: - Abbreviazioni e correzioni

    private func scheduleBoundaryFix(boundary: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            self?.applyBoundaryFix(boundary: boundary)
        }
    }

    /// La parola appena finita: prima le abbreviazioni ("cmq" → "comunque"), poi le correzioni italiane.
    private func applyBoundaryFix(boundary: String) {
        guard let field = FocusReader.focusedField(), !field.isSecure,
              !prefs.isExcluded(field.bundleID), field.selection.length == 0 else { return }
        if ignoreOwnProcess, field.pid == getpid() { return }
        guard let before = FocusReader.text(before: field, max: 200), before.hasSuffix(boundary) else { return }
        if let found = Abbreviations.match(before: before, in: prefs.abbreviations) {
            if replaceWord(found.trigger, with: found.expansion, boundary: boundary, field: field, before: before) {
                stats.expansions += 1
            }
            return
        }
        guard prefs.italianCorrections, let last = ItalianRules.lastWord(before: before) else { return }
        let word = last.word
        var fixed = ItalianRules.correction(for: word)
        if fixed == nil, prefs.capitalizeSentences { fixed = ItalianRules.capitalized(word, before: last.prefix) }
        guard let fixed, fixed != word else { return }
        if replaceWord(word, with: fixed, boundary: boundary, field: field, before: before) {
            stats.corrections += 1
        }
    }

    /// Sostituisce `word`, che finisce subito prima del carattere di confine appena scritto, con `replacement`: via
    /// Accessibilità se l'app lo permette, altrimenti cancellando e riscrivendo, ma solo se nel frattempo non è
    /// cambiato niente. Vero se è andata.
    private func replaceWord(_ word: String, with replacement: String, boundary: String, field: FocusedField,
                             before: String) -> Bool {
        let boundaryUnits = boundary.utf16.count
        if FocusReader.replace(field, length: word.utf16.count, endingAt: field.caret - boundaryUnits, with: replacement,
                               keepAfter: boundaryUnits) {
            return true
        }
        guard let check = FocusReader.text(before: field, max: 200), check == before else { return false }
        TextInserter.deleteBackward(word.count + boundary.count)
        TextInserter.type(replacement + boundary)
        return true
    }

    // MARK: - Controlli dall'esterno

    func forgetPhrases() {
        memory.forgetAll()
        diag(.app, "phrase memory cleared")
    }

    func setEnabled(_ on: Bool) {
        prefs.enabled = on
        if !on { dismiss(reason: nil) }
        diag(.app, on ? "resumed" : "paused")
    }
}
