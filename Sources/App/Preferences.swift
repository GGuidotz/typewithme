// Le scelte di chi usa l'app, salvate in UserDefaults. Predefiniti sensati: si usa senza toccare nulla.

import Foundation

enum EngineChoice: String, CaseIterable, Codable, Identifiable {
    case auto, gemma, apple, rulesOnly
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: L("Automatico")
        case .gemma: "Gemma (llama.cpp)"
        case .apple: "Apple Intelligence"
        case .rulesOnly: L("Solo regole e memoria")
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Suggerimenti accesi (il menu nella barra li mette in pausa).
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled") } }
    /// Il motore scelto. Chiave nuova dalla 0.2.0: "Automatico" è il predefinito anche per chi aveva Apple Intelligence.
    @Published var engine: EngineChoice { didSet { save(engine, "engineChoice") } }
    @Published var length: SuggestionLength { didSet { save(length, "length") } }
    /// Parole al massimo nel suggerimento (slider, 1...20). Decide anche la lunghezza: 1 è solo la parola in corso.
    @Published var maxWords: Int {
        didSet {
            defaults.set(maxWords, forKey: "maxWords")
            let style = SuggestionLength.forWords(maxWords)
            if length != style { length = style }
        }
    }
    /// Secondi di pausa prima di chiedere un suggerimento.
    @Published var delay: Double { didSet { defaults.set(delay, forKey: "delay") } }
    @Published var acceptWord: KeyBinding { didSet { save(acceptWord, "acceptWord") } }
    @Published var acceptAll: KeyBinding { didSet { save(acceptAll, "acceptAll") } }
    @Published var dismiss: KeyBinding { didSet { save(dismiss, "dismiss") } }
    @Published var rewrite: KeyBinding { didSet { save(rewrite, "rewrite") } }
    @Published var proofread: KeyBinding { didSet { save(proofread, "proofread") } }
    @Published var synonyms: KeyBinding { didSet { save(synonyms, "synonyms") } }
    /// Il correttore (Proofreader.swift): ortografia mentre scrivi, e grammatica con Apple Intelligence se `grammarCheck`.
    @Published var proofreading: Bool { didSet { defaults.set(proofreading, forKey: "proofreading") } }
    @Published var grammarCheck: Bool { didSet { defaults.set(grammarCheck, forKey: "grammarCheck") } }
    /// Le parole che il correttore non segnala più ("Ignora"), in minuscolo.
    @Published var learnedWords: [String] { didSet { defaults.set(learnedWords, forKey: "learnedWords") } }
    /// Completamento a metà riga (sperimentale).
    @Published var midLine: Bool { didSet { defaults.set(midLine, forKey: "midLine") } }
    @Published var italianCorrections: Bool { didSet { defaults.set(italianCorrections, forKey: "italianCorrections") } }
    @Published var capitalizeSentences: Bool { didSet { defaults.set(capitalizeSentences, forKey: "capitalizeSentences") } }
    @Published var phraseMemory: Bool { didSet { defaults.set(phraseMemory, forKey: "phraseMemory") } }
    /// Le abbreviazioni che si espandono; nessuna in partenza.
    @Published var abbreviations: [Abbreviation] { didSet { save(abbreviations, "abbreviations") } }
    /// Gli appunti come contesto per il modello: lo si sceglie nella guida al primo avvio.
    @Published var clipboardContext: Bool { didSet { defaults.set(clipboardContext, forKey: "clipboardContext") } }
    @Published var clipboardDecided: Bool { didSet { defaults.set(clipboardDecided, forKey: "clipboardDecided") } }
    /// Il testo visibile nella finestra in primo piano come contesto (serve il permesso Registrazione schermo).
    @Published var screenContext: Bool { didSet { defaults.set(screenContext, forKey: "screenContext") } }
    /// Il titolo e il testo della finestra in cui scrivi, letti con Accessibilità: acceso in partenza.
    @Published var appContext: Bool { didSet { defaults.set(appContext, forKey: "appContext") } }
    /// Niente suggerimento quando la parola che stai scrivendo sembra già sbagliata.
    @Published var hideOnTypo: Bool { didSet { defaults.set(hideOnTypo, forKey: "hideOnTypo") } }
    /// A batteria: pausa più lunga, niente contesto dallo schermo, modello spento dopo i minuti di inattività.
    @Published var batterySaver: Bool { didSet { defaults.set(batterySaver, forKey: "batterySaver") } }
    /// Cronologia di scrittura (Personalizzazione): cifrata, solo sul Mac.
    @Published var recordHistory: Bool { didSet { defaults.set(recordHistory, forKey: "recordHistory") } }
    /// Registra il testo anche nei campi dove non hai accettato nessun suggerimento.
    @Published var recordWithoutAccepting: Bool { didSet { defaults.set(recordWithoutAccepting, forKey: "recordWithoutAccepting") } }
    /// Quanto i suggerimenti imitano le tue parole: 0 spento, 1 leggero, 2 medio, 3 forte.
    @Published var wordChoice: Int { didSet { defaults.set(wordChoice, forKey: "wordChoice") } }
    /// Bundle id delle app dove non suggerire mai.
    @Published var excludedApps: Set<String> { didSet { save(Array(excludedApps).sorted(), "excludedApps") } }
    /// Una frase di istruzioni per il modello (tono, stile).
    @Published var instructions: String { didSet { defaults.set(instructions, forKey: "instructions") } }
    /// Istruzioni per app: bundle id → frase.
    @Published var appInstructions: [String: String] { didSet { save(appInstructions, "appInstructions") } }
    /// Il modello di Gemma scelto (ModelCatalog) e quelli aggiunti da chi usa l'app.
    @Published var selectedModelID: String { didSet { defaults.set(selectedModelID, forKey: "selectedModelID") } }
    @Published var customModels: [ModelEntry] { didSet { save(customModels, "customModels") } }
    /// Il modello resta caricato finché l'app è aperta (alla corrente): il primo suggerimento dopo una pausa non aspetta
    /// l'avvio del server. Spento: il server si spegne dopo `llamaIdleMinutes`.
    @Published var keepModelLoaded: Bool { didSet { defaults.set(keepModelLoaded, forKey: "keepModelLoaded") } }
    /// Minuti senza richieste prima di spegnere il server di llama.cpp.
    @Published var llamaIdleMinutes: Double { didSet { defaults.set(llamaIdleMinutes, forKey: "llamaIdleMinutes") } }
    /// Se Ollama è aperto e ha il modello, si usa lui invece di avviare llama-server.
    @Published var useOllama: Bool { didSet { defaults.set(useOllama, forKey: "useOllama") } }
    /// Dove sta llama-server, se l'ha scelto chi usa l'app; nil: lo si cerca in /opt/homebrew/bin e /usr/local/bin.
    @Published var llamaServerPath: String? { didSet { defaults.set(llamaServerPath, forKey: "llamaServerPath") } }
    /// Parole accettate da sempre: un numero che fa piacere vedere.
    @Published var acceptedWordsTotal: Int { didSet { defaults.set(acceptedWordsTotal, forKey: "acceptedWordsTotal") } }
    /// Le statistiche di Cotypist sono già state sommate al contatore.
    @Published var cotypistImported: Bool { didSet { defaults.set(cotypistImported, forKey: "cotypistImported") } }
    /// Parole accettate nel giorno `acceptedWordsDay` ("2026-10-28").
    @Published private(set) var acceptedWordsToday: Int { didSet { defaults.set(acceptedWordsToday, forKey: "acceptedWordsToday") } }
    @Published private(set) var acceptedWordsDay: String { didSet { defaults.set(acceptedWordsDay, forKey: "acceptedWordsDay") } }
    /// La guida dei primi passi è già stata vista.
    @Published var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }
    @Published var language: AppLanguage {
        didSet { Localization.language = language; save(language, "language") }
    }
    @Published var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }

    init() {
        func load<T: Decodable>(_ key: String, _ fallback: T) -> T {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
            return value
        }
        let d = UserDefaults.standard
        enabled = d.object(forKey: "enabled") as? Bool ?? true
        // Dalla 0.1.0 resta solo "Solo regole e memoria", che era una scelta; Apple Intelligence era il predefinito.
        let old: EngineChoice? = load("engine", Optional<EngineChoice>.none)
        engine = load("engineChoice", old == .rulesOnly ? EngineChoice.rulesOnly : EngineChoice.auto)
        // Dalla 0.3.0 lo slider: chi aveva scelto una lunghezza parte dal suo numero di parole (al massimo 20).
        let savedLength = load("length", SuggestionLength.medium)
        let words = min(max(d.object(forKey: "maxWords") as? Int ?? savedLength.maxWords, 1), SuggestionLength.maxSlider)
        maxWords = words
        length = SuggestionLength.forWords(words)
        // Dalla 0.3.0 la pausa predefinita è 120 ms: la richiesta si annulla comunque se riprendi a scrivere. Chi
        // aveva il vecchio predefinito (350 ms) passa al nuovo una volta sola.
        var savedDelay = d.object(forKey: "delay") as? Double
        if !d.bool(forKey: "delayDefault030") {
            d.set(true, forKey: "delayDefault030")
            if let old = savedDelay, abs(old - 0.35) < 0.001 { savedDelay = nil; d.removeObject(forKey: "delay") }
        }
        delay = savedDelay ?? 0.12
        acceptWord = load("acceptWord", KeyBinding.tab)
        acceptAll = load("acceptAll", KeyBinding.shiftTab)
        dismiss = load("dismiss", KeyBinding.escape)
        rewrite = load("rewrite", KeyBinding.controlOptionR)
        proofread = load("proofread", KeyBinding.controlOptionG)
        synonyms = load("synonyms", KeyBinding.controlOptionS)
        proofreading = d.object(forKey: "proofreading") as? Bool ?? true
        grammarCheck = d.object(forKey: "grammarCheck") as? Bool ?? true
        learnedWords = d.stringArray(forKey: "learnedWords") ?? []
        midLine = d.bool(forKey: "midLine")
        italianCorrections = d.object(forKey: "italianCorrections") as? Bool ?? true
        capitalizeSentences = d.object(forKey: "capitalizeSentences") as? Bool ?? true
        phraseMemory = d.object(forKey: "phraseMemory") as? Bool ?? true
        abbreviations = load("abbreviations", [Abbreviation]())
        clipboardContext = d.bool(forKey: "clipboardContext")
        clipboardDecided = d.bool(forKey: "clipboardDecided")
        screenContext = d.bool(forKey: "screenContext")
        appContext = d.object(forKey: "appContext") as? Bool ?? true
        hideOnTypo = d.object(forKey: "hideOnTypo") as? Bool ?? true
        batterySaver = d.object(forKey: "batterySaver") as? Bool ?? true
        recordHistory = d.bool(forKey: "recordHistory")
        recordWithoutAccepting = d.object(forKey: "recordWithoutAccepting") as? Bool ?? true
        wordChoice = d.object(forKey: "wordChoice") as? Int ?? 1
        excludedApps = Set(load("excludedApps", Exclusions.defaults))
        instructions = d.string(forKey: "instructions") ?? ""
        appInstructions = load("appInstructions", [String: String]())
        selectedModelID = d.string(forKey: "selectedModelID") ?? ModelCatalog.defaultID
        customModels = load("customModels", [ModelEntry]())
        // Con 8 GB o meno il modello sempre in memoria (pesi, cache, memoria della GPU: oltre un GB) manda il Mac a usare
        // lo swap: lì si spegne dopo i minuti scelti, a meno che non lo chieda chi usa l'app.
        keepModelLoaded = d.object(forKey: "keepModelLoaded") as? Bool ?? (ProcessInfo.processInfo.physicalMemory > 8 << 30)
        llamaIdleMinutes = d.object(forKey: "llamaIdleMinutes") as? Double ?? 10
        useOllama = d.object(forKey: "useOllama") as? Bool ?? true
        llamaServerPath = d.string(forKey: "llamaServerPath")
        acceptedWordsTotal = d.integer(forKey: "acceptedWordsTotal")
        cotypistImported = d.bool(forKey: "cotypistImported")
        acceptedWordsToday = d.integer(forKey: "acceptedWordsToday")
        acceptedWordsDay = d.string(forKey: "acceptedWordsDay") ?? ""
        onboardingDone = d.bool(forKey: "onboardingDone")
        language = load("language", AppLanguage.system)
        autoCheckUpdates = d.object(forKey: "autoCheckUpdates") as? Bool ?? true
        Localization.language = language
    }

    func isExcluded(_ bundleID: String) -> Bool { excludedApps.contains(bundleID) }

    func setExcluded(_ bundleID: String, _ excluded: Bool) {
        if excluded { excludedApps.insert(bundleID) } else { excludedApps.remove(bundleID) }
    }

    func resetExclusions() { excludedApps = Set(Exclusions.defaults) }

    /// Il modello di Gemma scelto, con i dati del catalogo.
    var selectedModel: ModelEntry { ModelCatalog.entry(id: selectedModelID, custom: customModels) }

    /// La frase per l'app con quel bundle id, vuota se non c'è.
    func instruction(forApp bundleID: String) -> String { appInstructions[bundleID] ?? "" }

    // MARK: - Parole accettate

    /// Conta `count` parole accettate, oggi e da sempre.
    func addAcceptedWords(_ count: Int) {
        guard count > 0 else { return }
        let today = Self.dayStamp(Date())
        if acceptedWordsDay != today {
            acceptedWordsDay = today
            acceptedWordsToday = 0
        }
        acceptedWordsToday += count
        acceptedWordsTotal += count
    }

    /// Le parole accettate oggi (zero se l'ultimo conteggio è di un altro giorno).
    var acceptedToday: Int { acceptedWordsDay == Self.dayStamp(Date()) ? acceptedWordsToday : 0 }

    private static func dayStamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
