// Il server di Gemma: llama-server di llama.cpp come processo figlio, solo su 127.0.0.1, su una porta libera scelta a
// caso. Parte alla prima richiesta che vuole Gemma (a tastiera ferma non gira niente), scarica il modello la prima
// volta (-hf: nella cache di llama.cpp, ~/Library/Caches/llama.cpp), si spegne dopo qualche minuto senza richieste e
// quando l'app si chiude. Se Ollama è aperto e ha già il modello, si usa lui e non si avvia niente.
// Il registro del processo resta in memoria, corto e senza percorsi: serve solo alla diagnostica.

import Combine
import Foundation

@MainActor
final class LlamaServer: ObservableObject {
    enum State: Equatable {
        case stopped, starting, downloading, ready, failed(String)

        /// Una frase per le impostazioni.
        var title: String {
            switch self {
            case .stopped: L("Fermo: si avvia quando serve")
            case .starting: L("Si avvia…")
            case .downloading: L("Sto scaricando il modello…")
            case .ready: L("Pronto")
            case .failed(let why): why
            }
        }

        /// Per il report di diagnostica, in inglese.
        var diagnostic: String {
            switch self {
            case .stopped: "stopped"
            case .starting: "starting"
            case .downloading: "downloading the model"
            case .ready: "ready"
            case .failed(let why): "failed: \(why)"
            }
        }

        var isBusy: Bool { self == .starting || self == .downloading }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    enum Backend: String {
        /// Dentro l'app (LlamaRuntime): niente server, niente HTTP.
        case inProcess = "in-app"
        case llamaServer = "llama-server"
        case ollama = "Ollama"
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var backend: Backend?
    /// Il motore da usare, solo quando il server (o il modello dentro l'app) è pronto.
    @Published private(set) var engine: (any GemmaEngine)?
    /// I modelli che Ollama ha già scaricato; nil se Ollama non è aperto (o non si è ancora controllato).
    @Published private(set) var ollamaModels: [String]?
    /// llama-server c'è (nel percorso scelto o in quelli di Homebrew).
    @Published private(set) var isInstalled: Bool
    /// L'ultima riga d'errore del registro di llama-server, senza percorsi: aiuta a capire un avvio fallito.
    @Published private(set) var lastLogLine: String?

    private let prefs: Preferences
    private var process: Process?
    private var currentEntry: ModelEntry?
    private var attempts = 0
    private var minimalArguments = false
    private var launchedAt = Date.distantPast
    private var failedAt = Date.distantPast
    private var lastUse = Date()
    private var startTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var idleTimer: Timer?
    private var logLines: [String] = []
    private var logPending = ""
    private var bag = Set<AnyCancellable>()

    static let maxAttempts = 3

    init(prefs: Preferences) {
        self.prefs = prefs
        isInstalled = Self.findExecutable(custom: prefs.llamaServerPath) != nil
        // Cambia il modello, Ollama sì o no, il percorso: il server riparte con le scelte nuove.
        prefs.$selectedModelID.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &bag)
        prefs.$useOllama.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &bag)
        prefs.$llamaServerPath.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &bag)
    }

    // MARK: - Che cosa c'è

    /// Il percorso di llama-server: quello scelto (un file o la cartella che lo contiene), poi quello incluso nell'app,
    /// poi Homebrew.
    static func findExecutable(custom: String?) -> String? {
        let fm = FileManager.default
        if let custom = custom?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                let inside = (expanded as NSString).appendingPathComponent("llama-server")
                if fm.isExecutableFile(atPath: inside) { return inside }
            } else if fm.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }
        if let bundled = bundledExecutable { return bundled }
        for directory in Homebrew.binDirectories {
            let path = directory + "/llama-server"
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Il llama-server incluso nell'app (build.sh lo mette in Contents/Helpers/llama), solo su Apple silicon.
    static var bundledExecutable: String? {
        #if arch(arm64)
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llama/llama-server").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        #else
        return nil
        #endif
    }

    /// La versione di llama.cpp inclusa nell'app ("b6500"), nil se non c'è.
    static var bundledTag: String? { bundledExecutable == nil ? nil : Bundle.main.infoDictionary?["SGRLlamaTag"] as? String }

    /// Ricontrolla se llama.cpp è installato (dopo "Installa nel Terminale", a finestra aperta).
    func refreshInstalled() {
        let now = Self.findExecutable(custom: prefs.llamaServerPath) != nil
        if now != isInstalled { isInstalled = now }
    }

    /// Chiede a Ollama quali modelli ha (una richiesta a localhost, solo quando serve saperlo).
    func refreshOllama() {
        Task { [weak self] in
            let models = await LocalHTTP.ollamaModels()
            self?.ollamaModels = models
        }
    }

    var ollamaRunning: Bool { ollamaModels != nil }

    /// Ollama è aperto e ha già il modello.
    func ollamaHas(_ entry: ModelEntry) -> Bool {
        guard let name = entry.ollamaName, let models = ollamaModels else { return false }
        return Self.contains(models, name)
    }

    static func contains(_ models: [String], _ name: String) -> Bool {
        if models.contains(name) { return true }
        if !name.contains(":") { return models.contains(name + ":latest") }
        return false
    }

    /// Gemma si può usare (subito o dopo l'avvio): per la scelta "Automatico".
    var isAvailable: Bool {
        let entry = prefs.selectedModel
        if isInstalled, entry.hfRepo != nil || entry.localPath != nil { return true }
        return prefs.useOllama && ollamaHas(entry)
    }

    /// Il nome del modello in uso, o di quello scelto se il server è fermo.
    var modelTitle: String { currentEntry?.title ?? prefs.selectedModel.title }

    /// Le ultime righe del registro, senza percorsi (per la diagnostica).
    var recentLog: [String] { Array(logLines.suffix(8)) }

    // MARK: - Avvio e spegnimento

    /// Una richiesta vuole Gemma: conta come uso e, se il server è fermo, lo avvia. Dopo un errore riprova al più
    /// una volta al minuto.
    func noteUse() {
        lastUse = Date()
        switch state {
        case .stopped:
            start()
        case .failed:
            if Date().timeIntervalSince(failedAt) > 60 { start() }
        default:
            break
        }
    }

    /// Avvia il server (o si collega a Ollama). Da "Avvia ora" o dalla prima richiesta.
    func start() {
        if state.isBusy || state == .ready { return }
        let entry = prefs.selectedModel
        let askOllama = prefs.useOllama && entry.ollamaName != nil
        lastUse = Date()
        lastLogLine = nil
        logLines = []
        logPending = ""
        minimalArguments = false
        currentEntry = entry
        state = .starting
        startTask?.cancel()
        startTask = Task { [weak self] in
            var models: [String]?
            if askOllama { models = await LocalHTTP.ollamaModels() }
            guard let self, !Task.isCancelled, self.state == .starting else { return }
            if askOllama { self.ollamaModels = models }
            if let name = entry.ollamaName, let models, Self.contains(models, name) {
                self.connectOllama(entry, name: name)
            } else if !(await self.loadInProcess(entry)) {
                guard self.state == .starting else { return }
                self.launch(entry, attempt: 1)
            }
        }
    }

    /// Ferma il server (o lascia Ollama): il motore non c'è più finché non riparte.
    func stop() {
        startTask?.cancel()
        startTask = nil
        healthTask?.cancel()
        healthTask = nil
        idleTimer?.invalidate()
        idleTimer = nil
        if let running = process {
            process = nil
            if running.isRunning { running.terminate() }
        }
        engine = nil
        backend = nil
        if state != .stopped { state = .stopped }
    }

    /// L'app si chiude: niente processi lasciati in giro.
    func terminate() {
        if process != nil { diag(.engine, "gemma server stopped at quit") }
        stop()
    }

    private func settingsChanged() {
        refreshInstalled()
        let wasRunning = state == .ready || state.isBusy
        stop()
        if wasRunning { start() }
    }

    /// Un modello base già sul Mac si carica dentro l'app (LlamaRuntime): la prima parola arriva in poche decine di
    /// millisecondi invece di un centinaio, e si riusano anche i token che il modello ha appena generato. Falso se non si
    /// può (librerie non incluse, modello istruito o da scaricare, caricamento fallito): allora si avvia llama-server.
    private func loadInProcess(_ entry: ModelEntry) async -> Bool {
        #if TWM_INPROCESS_LLAMA
        guard LlamaRuntime.isAvailable, entry.usesRawCompletion, let path = Self.modelPath(entry) else { return false }
        launchedAt = Date()
        let runtime = await Task.detached(priority: .userInitiated) { try? LlamaRuntime(path: path) }.value
        guard state == .starting, currentEntry?.id == entry.id else { return true }   // fermato o cambiato nel frattempo
        guard let runtime else {
            diag(.engine, "gemma in-app failed to load, falling back to llama-server")
            return false
        }
        backend = .inProcess
        engine = LocalGemmaEngine(runtime: runtime, displayName: entry.title)
        state = .ready
        scheduleIdleTimer()
        diag(.engine, "gemma in-app ready after \(Int(Date().timeIntervalSince(launchedAt) * 1000)) ms")
        return true
        #else
        return false
        #endif
    }

    /// Il file GGUF del modello: quello scelto sul Mac, o quello che llama.cpp ha già scaricato nella sua cache.
    static func modelPath(_ entry: ModelEntry) -> String? {
        if let local = entry.localPath { return FileManager.default.fileExists(atPath: local) ? local : nil }
        return cachedFile(entry)?.path
    }

    private func connectOllama(_ entry: ModelEntry, name: String) {
        backend = .ollama
        engine = LlamaEngine(baseURL: LocalHTTP.ollamaBase, model: name, displayName: entry.title, rawCompletion: false)
        state = .ready
        scheduleIdleTimer()
        diag(.engine, "gemma via Ollama (\(entry.id))")
    }

    private func launch(_ entry: ModelEntry, attempt: Int) {
        guard let path = Self.findExecutable(custom: prefs.llamaServerPath) else {
            isInstalled = false
            if prefs.useOllama, ollamaRunning, let name = entry.ollamaName {
                fail(L("Ollama è aperto ma non ha %@: scaricalo con \"ollama pull %@\", oppure installa llama.cpp.", name, name))
            } else {
                fail(L("llama.cpp non è installato."))
            }
            return
        }
        // Da dove viene il modello: un file già sul Mac (-m) o un repository Hugging Face da scaricare (-hf).
        let source: [String]
        if let local = entry.localPath, FileManager.default.fileExists(atPath: local) {
            source = ["-m", local]
        } else if let repo = entry.hfRepo, !repo.isEmpty {
            source = ["-hf", repo]
        } else if entry.localPath != nil {
            fail(L("Il file del modello non c'è più: scegli un altro modello in Impostazioni › Motori."))
            return
        } else {
            fail(L("Questo modello si usa solo con Ollama: apri Ollama e scaricalo con \"ollama pull\"."))
            return
        }
        let port = Self.freePort()
        let cached = Self.isCached(entry)
        // Da verificare sul Mac con la versione di Homebrew: --no-webui e --cache-reuse ci sono nelle versioni del
        // 2025; se llama-server li rifiuta, il tentativo dopo parte senza.
        var arguments = ["--host", "127.0.0.1", "--port", "\(port)"] + source + ["-c", "2048", "-ngl", "99"]
        // Un solo slot: ogni richiesta trova la cache del prompt di quella prima. --swa-full: Gemma 3 usa
        // l'attenzione a finestra scorrevole e senza una cache piena llama.cpp rifà tutto il prompt a ogni richiesta.
        if !minimalArguments { arguments += ["--no-webui", "--cache-reuse", "256", "-np", "1", "--swa-full"] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.appendLog(text) }
            }
        }
        p.terminationHandler = { [weak self] ended in
            let pid = ended.processIdentifier
            let code = ended.terminationStatus
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.processEnded(pid: pid, code: code) }
            }
        }
        do {
            try p.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            fail(L("llama.cpp non si avvia: %@", error.localizedDescription))
            return
        }
        process = p
        attempts = attempt
        launchedAt = Date()
        diag(.engine, "gemma server launched (\(entry.id), attempt \(attempt), model \(cached ? "cached" : "to download"))")
        watchHealth(port: port, pid: p.processIdentifier, entry: entry, cached: cached)
    }

    /// GET /health ogni mezzo secondo finché risponde 200 (llama-server risponde 503 mentre carica il modello).
    private func watchHealth(port: Int, pid: Int32, entry: ModelEntry, cached: Bool) {
        healthTask?.cancel()
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return }
        let begin = Date()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let healthy = await LocalHTTP.isOK(url, timeout: 2)
                guard let self, !Task.isCancelled, self.process?.processIdentifier == pid else { return }
                if healthy {
                    self.becameReady(port: port, entry: entry)
                    return
                }
                let waited = Date().timeIntervalSince(begin)
                // Il modello non è nella cache e dopo qualche secondo non è pronto: lo sta scaricando.
                if waited > 3, !cached, self.state == .starting { self.state = .downloading }
                if waited > 1800 {
                    self.stop()
                    self.fail(L("llama.cpp non è stato pronto in mezz'ora: riprova, o scegli un modello più piccolo."))
                    return
                }
            }
        }
    }

    private func becameReady(port: Int, entry: ModelEntry) {
        guard let base = URL(string: "http://127.0.0.1:\(port)") else { return }
        backend = .llamaServer
        engine = LlamaEngine(baseURL: base, model: entry.id, displayName: entry.title, rawCompletion: entry.usesRawCompletion)
        state = .ready
        lastLogLine = nil
        scheduleIdleTimer()
        diag(.engine, "gemma server ready after \(Int(Date().timeIntervalSince(launchedAt))) s")
    }

    private func processEnded(pid: Int32, code: Int32) {
        guard let running = process, running.processIdentifier == pid else { return }
        process = nil
        healthTask?.cancel()
        healthTask = nil
        engine = nil
        backend = nil
        diag(.engine, "gemma server exited with code \(code)")
        // Morto subito durante l'avvio (porta occupata, opzione sconosciuta): si riprova, al massimo tre volte.
        let early = Date().timeIntervalSince(launchedAt) < 8
        if state.isBusy, early, attempts < Self.maxAttempts, let entry = currentEntry {
            let log = logLines.joined(separator: "\n").lowercased()
            if log.contains("invalid argument") || log.contains("unknown argument") || log.contains("error: unrecognized") {
                minimalArguments = true
            }
            launch(entry, attempt: attempts + 1)
            return
        }
        if state == .ready || state.isBusy {
            var why = L("llama.cpp si è chiuso (codice %d).", Int(code))
            if let line = lastLogLine { why += " " + line }
            fail(why)
        }
    }

    private func fail(_ why: String) {
        idleTimer?.invalidate()
        idleTimer = nil
        engine = nil
        backend = nil
        failedAt = Date()
        state = .failed(why)
        diag(.engine, "gemma unavailable: \(why)")
    }

    // MARK: - Inattività

    /// Un controllo al minuto, solo mentre il server è acceso, con tolleranza alta (macOS lo accorpa ad altro).
    private func scheduleIdleTimer() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func checkIdle() {
        // Modello sempre pronto: si spegne solo con l'app (o a batteria, se chi usa l'app lo chiede).
        if prefs.keepModelLoaded, !shouldSaveEnergy { return }
        let idle = Date().timeIntervalSince(lastUse)
        guard idle > max(1, prefs.llamaIdleMinutes) * 60 else { return }
        diag(.engine, "gemma stopped after \(Int(idle / 60)) idle minutes")
        stop()
    }

    /// Vero quando conviene non tenere il modello in memoria senza motivo: a batteria, se la modalità batteria è accesa.
    var shouldSaveEnergy: Bool { prefs.batterySaver && Power.shouldSave }

    // MARK: - Registro

    private func appendLog(_ chunk: String) {
        logPending += chunk
        var parts = logPending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        logPending = parts.removeLast()
        if logPending.count > 2000 { logPending = String(logPending.suffix(500)) }
        // Dopo l'avvio contano solo gli errori: le righe delle richieste non servono e non si tengono.
        let collecting = state != .ready
        for raw in parts {
            let line = Self.sanitized(raw)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            let isError = lower.contains("error") || lower.contains("failed")
            if !collecting && !isError { continue }
            logLines.append(line)
            if isError { lastLogLine = line }
            if state == .starting, lower.contains("download") { state = .downloading }
        }
        if logLines.count > 40 { logLines.removeFirst(logLines.count - 40) }
    }

    /// Una riga del registro senza percorsi di file (né la cartella di casa) e non troppo lunga.
    static func sanitized(_ raw: String) -> String {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        line = line.replacingOccurrences(of: "[~/][^\\s'\"]*/[^\\s'\"]*", with: "…", options: .regularExpression)
        if line.count > 200 { line = String(line.prefix(200)) + "…" }
        return line
    }

    // MARK: - Pezzi

    /// Una porta libera tra 49152 e 65535: si prova a occuparla con un socket e la si lascia subito.
    static func freePort() -> Int {
        for _ in 0..<20 {
            let port = Int.random(in: 49152...65535)
            if isFree(port) { return port }
        }
        return Int.random(in: 49152...65535)
    }

    private static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Vero se nella cache di llama.cpp c'è già un file GGUF di quel modello (da verificare sul Mac: i nomi dei file
    /// cambiano tra le versioni di llama.cpp, ma contengono il nome del repository).
    static func isCached(_ entry: ModelEntry) -> Bool {
        if entry.localPath != nil { return true }
        return cachedFile(entry) != nil
    }

    /// Il file GGUF del modello nella cache di llama.cpp, se c'è.
    static func cachedFile(_ entry: ModelEntry) -> URL? {
        guard let repo = entry.hfRepo else { return nil }
        let last = repo.split(separator: "/").last.map(String.init) ?? repo
        let name = last.lowercased().replacingOccurrences(of: "-gguf", with: "")
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let base = caches.appendingPathComponent("llama.cpp", isDirectory: true)
        guard let files = fm.enumerator(at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        var seen = 0
        for case let url as URL in files {
            seen += 1
            if seen > 1000 { break }
            let file = url.lastPathComponent.lowercased()
            if file.hasSuffix(".gguf"), file.contains(name), !file.hasPrefix("mmproj") { return url }
        }
        return nil
    }
}
