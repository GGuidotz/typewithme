// Gemma via llama.cpp (il nostro llama-server, Sources/App/Engines/LlamaServer.swift) o via Ollama: tutti e due
// espongono su localhost lo stesso endpoint compatibile con OpenAI, POST /v1/chat/completions. Il testo va solo a
// 127.0.0.1, mai in rete. Il seguito arriva a pezzi (stream: true, righe SSE "data: {...}" fino a "data: [DONE]").
// Un motore per server avviato: indirizzo e nome del modello non cambiano, se il server cambia se ne crea un altro.
// Con un modello base (rawCompletion) si usa invece l'endpoint nativo /completion di llama-server: il prompt è il
// testo prima del cursore e il modello lo continua così com'è, senza istruzioni. Per riscrivere serve un modello istruito.

import Foundation

/// I tempi che llama-server mette nell'ultimo pezzo della risposta ("timings"): quanti token di prompt ha elaborato,
/// quanti ha ripreso dalla cache e quanto ci ha messo. Solo numeri, per la diagnostica.
struct LlamaTimings: Equatable, Sendable {
    var promptTokens: Int
    var cachedTokens: Int?
    var promptMs: Double
    var predictedTokens: Int
    var predictedMs: Double

    init(promptTokens: Int, cachedTokens: Int?, promptMs: Double, predictedTokens: Int, predictedMs: Double) {
        self.promptTokens = promptTokens
        self.cachedTokens = cachedTokens
        self.promptMs = promptMs
        self.predictedTokens = predictedTokens
        self.predictedMs = predictedMs
    }

    init?(_ chunk: [String: Any]) {
        guard let t = chunk["timings"] as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? { (t[key] as? NSNumber)?.doubleValue }
        guard let promptN = number("prompt_n"), let promptMs = number("prompt_ms") else { return nil }
        promptTokens = Int(promptN)
        self.promptMs = promptMs
        predictedTokens = Int(number("predicted_n") ?? 0)
        predictedMs = number("predicted_ms") ?? 0
        if let cache = number("cache_n") { cachedTokens = Int(cache) }
        else if let cached = (chunk["tokens_cached"] as? NSNumber)?.intValue { cachedTokens = Swift.max(0, cached - promptTokens) }
    }
}

/// Come è finita l'ultima risposta di un modello base: perché si è fermata e quante parole ha tenuto. Solo numeri.
struct LlamaStop: Equatable, Sendable {
    var reason: String
    var words: Int
    /// Il seguito è partito da una parola del modello personale.
    var personal = false
}

final class LlamaEngine: CompletionEngine, @unchecked Sendable {
    let kind = EngineKind.gemma
    let displayName: String
    /// Circa 1.200 caratteri (300-400 token): abbastanza per il tono e il filo del discorso, pochi da rielaborare
    /// quando la cache del prompt non basta. Il server parte con 2048 token.
    let contextLimit = 1200
    let baseURL: URL
    /// Il campo "model" della richiesta: per Ollama il nome del modello, per llama-server è indifferente.
    let model: String
    /// Modello base: continuazione pura via /completion (solo con il nostro llama-server).
    let rawCompletion: Bool

    var unavailableReason: String? { nil }

    private let lock = NSLock()
    private var timings: LlamaTimings?
    private var stopped: LlamaStop?
    /// I tempi dell'ultima risposta arrivata fino in fondo, se il server li ha dati.
    var lastTimings: LlamaTimings? { lock.withLock { timings } }
    /// Come è finita l'ultima risposta (solo modelli base).
    var lastStop: LlamaStop? { lock.withLock { stopped } }
    private func note(_ chunk: [String: Any]) {
        guard let t = LlamaTimings(chunk) else { return }
        lock.withLock { timings = t }
    }

    init(baseURL: URL, model: String, displayName: String, rawCompletion: Bool = false) {
        self.baseURL = baseURL
        self.model = model
        self.displayName = displayName
        self.rawCompletion = rawCompletion
    }

    func complete(_ request: CompletionRequest, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        lock.withLock { timings = nil; stopped = nil }
        if rawCompletion { return try await completeRaw(request, partial: partial) }
        let body = Self.body(model: model, system: Prompting.completionInstructions(request),
                             user: Prompting.completionPrompt(request), maxTokens: request.maxTokens,
                             temperature: 0.2, stream: true)
        let (bytes, response) = try await LocalHTTP.session.bytes(for: chatRequest(body))
        try Self.check(response)
        var text = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            if let message = Self.errorMessage(payload) { throw EngineError(message) }
            if payload.contains("\"timings\""), let chunk = Self.parse(payload) { note(chunk) }
            guard let piece = Self.content(payload), !piece.isEmpty else { continue }
            text += piece
            partial(text)
            // Un a capo dopo il primo pezzo vuol dire che il seguito è finito: si smette di leggere.
            if AppleEngine.endsLine(text) { break }
        }
        return text
    }

    /// Modello base: il prompt è il testo stesso, il modello lo continua. Si ferma a fine riga.
    private func completeRaw(_ request: CompletionRequest, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        let prompt = Prompting.rawPrompt(request)
        // Il modello personale: se una parola tua batte quella che Gemma sceglierebbe, il seguito parte da lì.
        var forced: (text: String, score: Double)?
        if !request.personal.isEmpty, request.personalWeight > 0 {
            // Se la prova non va, si continua senza: il modello personale è un di più.
            forced = (try? await personalChoice(request, prompt: prompt)) ?? nil
        }
        var object: [String: Any] = [:]
        object["prompt"] = prompt + (forced?.text ?? "")
        object["n_predict"] = request.maxTokens
        // La parola più probabile, sempre: suggerimenti stabili, e la probabilità di ogni token per decidere dove
        // fermarsi (ConfidenceStop). Niente stop a "\n": dopo una frase finita il modello va spesso a capo e il seguito
        // è la riga dopo (Prompting.cleanCompletion la prende); ci si ferma a fine riga, sotto. Niente penalità sulle
        // ripetizioni: in italiano colpiva proprio "di", "che", "la", e il seguito diventava innaturale.
        object["temperature"] = 0
        object["repeat_penalty"] = 1.0
        object["n_probs"] = 1
        object["cache_prompt"] = true
        object["stream"] = true
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("completion"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 10
        urlRequest.httpBody = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        let (bytes, response) = try await LocalHTTP.session.bytes(for: urlRequest)
        try Self.check(response)
        var stop = ConfidenceStop(length: request.length, maxWords: request.maxWords)
        if let forced { _ = stop.add(forced.text, logprob: log(Swift.max(forced.score, 0.01)), tokenCount: 1) }
        let markupAllowed = request.context.before.contains("<")
        var natural = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            if let message = Self.errorMessage(payload) { throw EngineError(message) }
            guard let chunk = Self.parse(payload) else { continue }
            note(chunk)
            if let piece = chunk["content"] as? String, !piece.isEmpty {
                let logprob = Self.logprob(chunk)
                if stop.add(piece, logprob: logprob?.sum, tokenCount: logprob?.tokens ?? 1) { break }
                // Si mostra solo quello di cui il modello è già sicuro: niente parole che compaiono e spariscono.
                if !stop.confident.isEmpty { partial(stop.confident) }
                // Finita la riga (dopo un eventuale a capo iniziale), il seguito è completo.
                if AppleEngine.endsLine(stop.text) { natural = true; break }
                // Un tag HTML: il resto sarebbe pagina web, non testo tuo (Prompting.cuttingMarkup lo toglie).
                if !markupAllowed, stop.text.range(of: "</?[A-Za-z]", options: .regularExpression) != nil {
                    natural = true
                    break
                }
            }
            if (chunk["stop"] as? Bool) == true {
                natural = (chunk["stop_type"] as? String) != "limit"
                break
            }
        }
        let result = stop.result(natural: natural)
        let ended = LlamaStop(reason: stop.reason?.rawValue ?? "unknown", words: TextTokens.words(withLeadingSpace: result).count,
                              personal: forced != nil)
        lock.withLock { stopped = ended }
        return result
    }

    /// Una richiesta da un token con le 10 alternative più probabili: se una parola del modello personale, pesata
    /// con `personalWeight`, batte quella che Gemma sceglierebbe, la si restituisce (con lo spazio giusto davanti, o
    /// senza l'inizio già scritto se si è a metà parola) e il suo punteggio. nil se vince Gemma. Costa una richiesta
    /// in più, quasi tutta dalla cache (pochi millisecondi).
    private func personalChoice(_ request: CompletionRequest, prompt: String) async throws -> (text: String, score: Double)? {
        let before = request.context.before
        let partial = request.context.partialWord
        func target(_ word: String) -> String? {
            if !partial.isEmpty {
                guard word.count > partial.count else { return nil }
                return String(word.dropFirst(partial.count))
            }
            guard let last = before.last else { return nil }
            return last.isWhitespace ? word : " " + word
        }
        var object: [String: Any] = [:]
        object["prompt"] = prompt
        object["n_predict"] = 1
        object["temperature"] = 0
        object["n_probs"] = 10
        object["cache_prompt"] = true
        object["stream"] = false
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("completion"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 5
        urlRequest.httpBody = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        let (data, response) = try await LocalHTTP.session.data(for: urlRequest)
        try Self.check(response)
        guard let chunk = Self.parse(String(decoding: data, as: UTF8.self)) else { return nil }
        let top = Self.alternatives(chunk)
        guard let greedy = top.first else { return nil }
        let weight = Swift.min(Swift.max(request.personalWeight, 0), 1)
        var best: (text: String, score: Double)?
        for candidate in request.personal {
            guard let text = target(candidate.word) else { continue }
            // Gemma va già da quella parte: niente da cambiare.
            if text.hasPrefix(greedy.token) || greedy.token.hasPrefix(text) { return nil }
            let model = top.filter { !$0.token.trimmingCharacters(in: .whitespaces).isEmpty && (text.hasPrefix($0.token) || $0.token.hasPrefix(text)) }
                .map { $0.probability }.max() ?? 0
            // Una parola che Gemma non mette nemmeno tra le prime dieci passa solo se nei tuoi testi è quasi sicura.
            if model == 0, candidate.probability < 0.7 { continue }
            let score = (1 - weight) * model + weight * candidate.probability
            if score > (best?.score ?? 0) { best = (text, score) }
        }
        guard let best, best.score > (1 - weight) * greedy.probability else { return nil }
        return best
    }

    /// Le alternative per il primo token di una risposta non a pezzi, le più probabili prima: "top_logprobs" (versioni
    /// nuove di llama-server), "top_probs" o "probs" (vecchie).
    static func alternatives(_ chunk: [String: Any]) -> [(token: String, probability: Double)] {
        guard let tokens = chunk["completion_probabilities"] as? [[String: Any]], let first = tokens.first else { return [] }
        let list = (first["top_logprobs"] ?? first["top_probs"] ?? first["probs"]) as? [[String: Any]] ?? []
        var out: [(token: String, probability: Double)] = []
        for item in list {
            guard let token = (item["token"] ?? item["tok_str"]) as? String else { continue }
            if let logprob = (item["logprob"] as? NSNumber)?.doubleValue { out.append((token, exp(logprob))) }
            else if let prob = (item["prob"] as? NSNumber)?.doubleValue { out.append((token, prob)) }
        }
        return out.sorted { $0.probability > $1.probability }
    }

    /// Il logprob del pezzo (la somma di quelli dei suoi token) e quanti token sono, da "completion_probabilities" di
    /// llama-server: "logprob" nelle versioni nuove, "prob" in quelle vecchie. nil se il server non lo dà.
    static func logprob(_ chunk: [String: Any]) -> (sum: Double, tokens: Int)? {
        guard let tokens = chunk["completion_probabilities"] as? [[String: Any]], !tokens.isEmpty else { return nil }
        var sum = 0.0
        for token in tokens {
            if let logprob = (token["logprob"] as? NSNumber)?.doubleValue { sum += logprob }
            else if let prob = (token["prob"] as? NSNumber)?.doubleValue { sum += log(Swift.max(prob, 1e-6)) }
            else if let probs = token["probs"] as? [[String: Any]], let first = probs.first,
                    let prob = (first["prob"] as? NSNumber)?.doubleValue { sum += log(Swift.max(prob, 1e-6)) }
            else { return nil }
        }
        return (sum, tokens.count)
    }

    func rewrite(_ text: String, instruction: String, language: String?) async throws -> String {
        if rawCompletion {
            throw EngineError(L("Questo modello continua il testo ma non segue istruzioni: per riscrivere scegli un modello istruito o Apple Intelligence."))
        }
        let body = Self.body(model: model, system: Prompting.rewriteInstructions(instruction, language: language),
                             user: Prompting.rewritePrompt(text), maxTokens: 600, temperature: 0.3, stream: false)
        var request = chatRequest(body)
        request.timeoutInterval = 30   // una riscrittura lunga può richiedere più dei 10 secondi del seguito
        let (data, response) = try await LocalHTTP.session.data(for: request)
        try Self.check(response)
        let payload = String(decoding: data, as: UTF8.self)
        if let message = Self.errorMessage(payload) { throw EngineError(message) }
        guard let content = Self.content(payload) else { throw EngineError(L("Il modello non ha risposto.")) }
        return content
    }

    // MARK: - Richiesta e risposta

    private func chatRequest(_ body: Data) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = body
        return request
    }

    private static func body(model: String, system: String, user: String, maxTokens: Int, temperature: Double,
                             stream: Bool) -> Data {
        let messages: [[String: String]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": user],
        ]
        var object: [String: Any] = [:]
        object["model"] = model
        object["messages"] = messages
        object["max_tokens"] = maxTokens
        object["temperature"] = temperature
        object["stream"] = stream
        object["cache_prompt"] = true   // llama-server: riusa il prompt già elaborato (Ollama ignora il campo)
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func check(_ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 404 { throw EngineError(L("Il modello non c'è sul server (se usi Ollama, scaricalo con ollama pull).")) }
            throw EngineError(L("Il server di Gemma ha risposto con un errore (%d).", code))
        }
    }

    /// Il testo di un pezzo (choices[0].delta.content) o di una risposta intera (choices[0].message.content).
    static func content(_ json: String) -> String? {
        guard let object = parse(json),
              let choices = object["choices"] as? [[String: Any]], let first = choices.first else { return nil }
        if let delta = first["delta"] as? [String: Any], let text = delta["content"] as? String { return text }
        if let message = first["message"] as? [String: Any], let text = message["content"] as? String { return text }
        return nil
    }

    /// Il messaggio d'errore del server, se la risposta è un errore ({"error": {"message": …}}).
    static func errorMessage(_ json: String) -> String? {
        guard let object = parse(json), let error = object["error"] else { return nil }
        if let detail = error as? [String: Any], let message = detail["message"] as? String { return message }
        if let message = error as? String { return message }
        return L("Il server di Gemma ha risposto con un errore.")
    }

    private static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Le chiamate a localhost: una sessione senza cache né cookie, con tempi corti. Solo 127.0.0.1.
enum LocalHTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30   // ogni richiesta mette il suo, più corto (10 s per il seguito)
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    /// Vero se GET `url` risponde 200 entro `timeout` secondi.
    static func isOK(_ url: URL, timeout: TimeInterval = 2) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let result = try? await session.data(for: request) else { return false }
        return (result.1 as? HTTPURLResponse)?.statusCode == 200
    }

    /// I modelli che Ollama ha già scaricato (GET /api/tags), nil se Ollama non è aperto.
    static func ollamaModels(timeout: TimeInterval = 1.5) async -> [String]? {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let result = try? await session.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return [] }
        var names: [String] = []
        for model in models {
            if let name = model["name"] as? String { names.append(name) }
            if let other = model["model"] as? String, !names.contains(other) { names.append(other) }
        }
        return names
    }

    static let ollamaBase = URL(string: "http://127.0.0.1:11434")!
}
