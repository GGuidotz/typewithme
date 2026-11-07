// Gemma dentro l'app: libllama di llama.cpp chiamata direttamente, senza server né HTTP né JSON. Il modello si
// carica una volta; il contesto tiene in memoria (cache KV) i token del prompt di prima, e a ogni richiesta si
// elabora solo la parte nuova: di solito i pochi caratteri scritti dall'ultima volta. Ogni token generato arriva con
// la sua probabilità e, se serve, con le alternative più probabili (per il modello personale), letti dai logit.
// Tutto su una coda sua, una richiesta alla volta; una richiesta nuova ferma quella in corso al token successivo.
// Si compila solo su Apple silicon con le librerie di llama.cpp incluse nell'app (build.sh: TWM_INPROCESS_LLAMA);
// altrimenti resta llama-server (LlamaServer.swift).

#if TWM_INPROCESS_LLAMA
import Foundation
import os

final class LlamaRuntime: @unchecked Sendable {
    /// Un token generato: il suo testo (vuoto se è un pezzo di un carattere UTF-8 non ancora finito), il logprob e,
    /// se chieste, le alternative più probabili con la loro probabilità.
    struct Step {
        var piece: String
        var logprob: Double
        var alternatives: [(token: String, probability: Double)]
    }

    /// Solo numeri, per la diagnostica (come LlamaTimings di llama-server).
    struct Timings {
        var promptTokens = 0
        var cachedTokens = 0
        var promptMs = 0.0
        var predictedTokens = 0
        var predictedMs = 0.0
    }

    enum Failure: Error { case load(String), tokenize, decode(Int32) }

    let contextSize: Int
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let vocabSize: Int
    private let addBOS: Bool
    private let queue = DispatchQueue(label: "com.gguidotz.typewithme.llama", qos: .userInitiated)
    /// I token che il contesto ha già elaborato, nell'ordine: il prefisso in comune con il prompt nuovo si riusa.
    private var cached: [llama_token] = []
    /// Cresce a ogni richiesta: quella in corso si ferma appena vede un numero diverso dal suo.
    private let current = OSAllocatedUnfairLock(initialState: 0)

    /// Le librerie di llama.cpp sono nell'app (Contents/Helpers/llama): senza, il motore dentro l'app non c'è.
    static var isAvailable: Bool {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llama/libllama.dylib").path
        return FileManager.default.fileExists(atPath: path)
    }

    private static let backend: Void = {
        llama_log_set({ _, _, _ in }, nil)   // il registro di llama.cpp non serve (e conterrebbe percorsi)
        llama_backend_init()
    }()

    /// Carica il modello (lento: secondi; mai sul thread principale). Gli strati sulla GPU, contesto di
    /// `contextSize` token, cache SWA piena: Gemma 3 usa l'attenzione a finestra e senza togliere token in coda
    /// dalla cache non si potrebbe.
    init(path: String, contextSize: Int = 2048) throws {
        _ = Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99
        guard let model = llama_model_load_from_file(path, modelParams) else { throw Failure.load("model") }
        var params = llama_context_default_params()
        params.n_ctx = UInt32(contextSize)
        params.n_batch = 512
        params.n_ubatch = 512
        params.n_seq_max = 1
        params.swa_full = true
        params.no_perf = true
        let cores = ProcessInfo.processInfo.activeProcessorCount
        params.n_threads = Int32(Swift.max(2, Swift.min(4, cores / 2)))
        params.n_threads_batch = params.n_threads
        guard let context = llama_init_from_model(model, params) else {
            llama_model_free(model)
            throw Failure.load("context")
        }
        guard let vocab = llama_model_get_vocab(model) else {
            llama_free(context)
            llama_model_free(model)
            throw Failure.load("vocab")
        }
        self.model = model
        self.context = context
        self.vocab = vocab
        self.contextSize = contextSize
        vocabSize = Int(llama_vocab_n_tokens(vocab))
        addBOS = llama_vocab_get_add_bos(vocab)
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    /// Ferma la richiesta in corso al prossimo token.
    func cancel() {
        current.withLock { $0 += 1 }
    }

    /// Continua `prompt` per al più `maxTokens` token, il più probabile ogni volta. `onStep` riceve ogni token e
    /// risponde true per fermarsi. `alternatives` > 0: per ogni token anche le alternative più probabili.
    /// Si blocca finché ha finito (va chiamato fuori dal thread principale: lo fa `run`).
    private func generate(prompt: String, maxTokens: Int, alternatives: Int, ticket: Int,
                          onStep: (Step) -> Bool) throws -> Timings {
        var timings = Timings()
        var tokens = try tokenize(prompt)
        // Il prompt deve stare nel contesto insieme al seguito: se è troppo lungo si tiene la fine.
        let room = contextSize - maxTokens - 4
        if tokens.count > room {
            let first = addBOS ? [tokens[0]] : []
            tokens = first + tokens.suffix(room - first.count)
        }
        guard !tokens.isEmpty else { return timings }
        // Quanto del prompt è già nella cache. Almeno un token si rielabora sempre: servono i suoi logit.
        var common = 0
        while common < Swift.min(cached.count, tokens.count), cached[common] == tokens[common] { common += 1 }
        if common == tokens.count { common -= 1 }
        let memory = llama_get_memory(context)
        if !llama_memory_seq_rm(memory, 0, llama_pos(common), -1) {
            llama_memory_clear(memory, true)
            common = 0
        }
        cached = Array(tokens[..<common])
        timings.cachedTokens = common
        let promptStart = Date()
        var index = common
        while index < tokens.count {
            if current.withLock({ $0 }) != ticket { return timings }
            // Pochi token (i caratteri scritti dall'ultima richiesta) uno alla volta: con Metal un lotto di dimensione
            // nuova costa la ricostruzione del grafo (oltre 100 ms per 2 token), uno solo circa 15 ms.
            let step = tokens.count - index <= 8 ? 1 : 512
            let end = Swift.min(tokens.count, index + step)
            var chunk = Array(tokens[index..<end])
            let result = chunk.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
            }
            guard result == 0 else {
                llama_memory_clear(memory, true)
                cached = []
                throw Failure.decode(result)
            }
            cached += chunk
            index = end
        }
        timings.promptTokens = tokens.count - common
        timings.promptMs = Date().timeIntervalSince(promptStart) * 1000

        let generationStart = Date()
        var pending: [UInt8] = []   // i byte di un carattere UTF-8 diviso tra due token
        for _ in 0..<maxTokens {
            if current.withLock({ $0 }) != ticket { break }
            guard let logits = llama_get_logits_ith(context, -1) else { break }
            let (token, logprob, top) = pick(logits, alternatives: alternatives)
            if llama_vocab_is_eog(vocab, token) { break }
            pending += bytes(of: token)
            var piece = ""
            if let text = String(validating: pending, as: UTF8.self) {
                piece = text
                pending = []
            } else if pending.count > 8 {
                piece = String(decoding: pending, as: UTF8.self)   // non è UTF-8 valido: meglio un segno che bloccarsi
                pending = []
            }
            let step = Step(piece: piece, logprob: logprob, alternatives: top)
            timings.predictedTokens += 1
            if onStep(step) { break }
            var next = token
            let result = withUnsafeMutablePointer(to: &next) { pointer in
                llama_decode(context, llama_batch_get_one(pointer, 1))
            }
            guard result == 0 else {
                llama_memory_clear(memory, true)
                cached = []
                throw Failure.decode(result)
            }
            cached.append(token)
        }
        timings.predictedMs = Date().timeIntervalSince(generationStart) * 1000
        return timings
    }

    /// Esegue `generate` sulla coda del motore, annullabile dal Task che aspetta.
    func run(prompt: String, maxTokens: Int, alternatives: Int = 0,
             onStep: @escaping (Step) -> Bool) async throws -> Timings {
        let ticket = current.withLock { value -> Int in
            value += 1
            return value
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Timings, Error>) in
                queue.async { [self] in
                    do {
                        continuation.resume(returning: try generate(prompt: prompt, maxTokens: maxTokens,
                                                                    alternatives: alternatives, ticket: ticket, onStep: onStep))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { [current] in
            current.withLock { value in if value == ticket { value += 1 } }
        }
    }

    // MARK: - Pezzi

    private func tokenize(_ text: String) throws -> [llama_token] {
        let utf8 = Array(text.utf8CString.dropLast())
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        var count = llama_tokenize(vocab, utf8, Int32(utf8.count), &tokens, Int32(tokens.count), addBOS, false)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, utf8, Int32(utf8.count), &tokens, Int32(tokens.count), addBOS, false)
        }
        guard count >= 0 else { throw Failure.tokenize }
        return Array(tokens.prefix(Int(count)))
    }

    private func bytes(of token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard count > 0 else { return [] }
        return buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
    }

    private func text(of token: llama_token) -> String {
        String(decoding: bytes(of: token), as: UTF8.self)
    }

    /// Il token più probabile, il suo logprob e (se chieste) le `alternatives` più probabili, dai logit grezzi.
    private func pick(_ logits: UnsafeMutablePointer<Float>, alternatives: Int) -> (llama_token, Double, [(token: String, probability: Double)]) {
        var best = 0
        var maxLogit = logits[0]
        for i in 1..<vocabSize where logits[i] > maxLogit {
            maxLogit = logits[i]
            best = i
        }
        var sum = 0.0
        for i in 0..<vocabSize { sum += exp(Double(logits[i] - maxLogit)) }
        let logSum = log(sum)
        let logprob = -logSum   // logits[best] - maxLogit = 0
        guard alternatives > 0 else { return (llama_token(best), logprob, []) }
        var top: [(index: Int, logit: Float)] = []
        for i in 0..<vocabSize {
            let value = logits[i]
            if top.count < alternatives {
                top.append((i, value))
                if top.count == alternatives { top.sort { $0.logit > $1.logit } }
            } else if value > top[alternatives - 1].logit {
                top[alternatives - 1] = (i, value)
                top.sort { $0.logit > $1.logit }
            }
        }
        top.sort { $0.logit > $1.logit }
        let list = top.map { (token: text(of: llama_token($0.index)), probability: exp(Double($0.logit - maxLogit) - logSum)) }
        return (llama_token(best), logprob, list)
    }
}
#endif

// MARK: - Il motore

/// Quello che il Completer legge da un motore Gemma, dentro l'app o via server: se è un modello base e come sono
/// andate le ultime risposte.
protocol GemmaEngine: CompletionEngine {
    var rawCompletion: Bool { get }
    var lastTimings: LlamaTimings? { get }
    var lastStop: LlamaStop? { get }
}

extension LlamaEngine: GemmaEngine {}

#if TWM_INPROCESS_LLAMA
/// Un modello base dentro l'app (LlamaRuntime): stesso comportamento della continuazione via llama-server
/// (LlamaEngine.completeRaw: il più probabile ogni volta, ConfidenceStop, modello personale, stop a fine riga e ai tag
/// HTML), senza HTTP. Solo modelli base: per riscrivere serve un modello istruito.
final class LocalGemmaEngine: GemmaEngine, @unchecked Sendable {
    let kind = EngineKind.gemma
    let displayName: String
    let contextLimit = 1200
    let rawCompletion = true
    var unavailableReason: String? { nil }

    private let runtime: LlamaRuntime
    private let lock = NSLock()
    private var timings: LlamaTimings?
    private var stopped: LlamaStop?
    var lastTimings: LlamaTimings? { lock.withLock { timings } }
    var lastStop: LlamaStop? { lock.withLock { stopped } }

    init(runtime: LlamaRuntime, displayName: String) {
        self.runtime = runtime
        self.displayName = displayName
    }

    func complete(_ request: CompletionRequest, partial: @escaping @Sendable (String) -> Void) async throws -> String {
        lock.withLock { timings = nil; stopped = nil }
        let prompt = Prompting.rawPrompt(request)
        var forced: (text: String, score: Double)?
        if !request.personal.isEmpty, request.personalWeight > 0 {
            forced = (try? await personalChoice(request, prompt: prompt)) ?? nil
        }
        let box = StopBox(stop: ConfidenceStop(length: request.length, maxWords: request.maxWords))
        if let forced { _ = box.stop.add(forced.text, logprob: log(Swift.max(forced.score, 0.01)), tokenCount: 1) }
        let markupAllowed = request.context.before.contains("<")
        // Un carattere UTF-8 diviso tra due token arriva con il secondo: il logprob del primo si somma.
        var carried = (logprob: 0.0, tokens: 0)
        let t = try await runtime.run(prompt: prompt + (forced?.text ?? ""), maxTokens: request.maxTokens) { step in
            carried.logprob += step.logprob
            carried.tokens += 1
            guard !step.piece.isEmpty else { return false }
            defer { carried = (0, 0) }
            if box.stop.add(step.piece, logprob: carried.logprob, tokenCount: carried.tokens) { return true }
            if !box.stop.confident.isEmpty { partial(box.stop.confident) }
            if AppleEngine.endsLine(box.stop.text) { box.natural = true; return true }
            if !markupAllowed, box.stop.text.range(of: "</?[A-Za-z]", options: .regularExpression) != nil {
                box.natural = true
                return true
            }
            return false
        }
        if t.predictedTokens < request.maxTokens, box.stop.reason == nil { box.natural = true }
        let result = box.stop.result(natural: box.natural)
        let ended = LlamaStop(reason: box.stop.reason?.rawValue ?? "unknown",
                              words: TextTokens.words(withLeadingSpace: result).count, personal: forced != nil)
        let summary = LlamaTimings(promptTokens: t.promptTokens, cachedTokens: t.cachedTokens, promptMs: t.promptMs,
                                   predictedTokens: t.predictedTokens, predictedMs: t.predictedMs)
        lock.withLock { stopped = ended; timings = summary }
        return result
    }

    /// Come LlamaEngine.personalChoice: un token con le 10 alternative, dai logit (quasi gratis: il prompt è in cache).
    private func personalChoice(_ request: CompletionRequest, prompt: String) async throws -> (text: String, score: Double)? {
        let before = request.context.before
        let partialWord = request.context.partialWord
        func target(_ word: String) -> String? {
            if !partialWord.isEmpty {
                guard word.count > partialWord.count else { return nil }
                return String(word.dropFirst(partialWord.count))
            }
            guard let last = before.last else { return nil }
            return last.isWhitespace ? word : " " + word
        }
        var top: [(token: String, probability: Double)] = []
        _ = try await runtime.run(prompt: prompt, maxTokens: 1, alternatives: 10) { step in
            top = step.alternatives
            return true
        }
        guard let greedy = top.first else { return nil }
        let weight = Swift.min(Swift.max(request.personalWeight, 0), 1)
        var best: (text: String, score: Double)?
        for candidate in request.personal {
            guard let text = target(candidate.word) else { continue }
            if text.hasPrefix(greedy.token) || greedy.token.hasPrefix(text) { return nil }
            let model = top.filter { !$0.token.trimmingCharacters(in: .whitespaces).isEmpty && (text.hasPrefix($0.token) || $0.token.hasPrefix(text)) }
                .map { $0.probability }.max() ?? 0
            if model == 0, candidate.probability < 0.7 { continue }
            let score = (1 - weight) * model + weight * candidate.probability
            if score > (best?.score ?? 0) { best = (text, score) }
        }
        guard let best, best.score > (1 - weight) * greedy.probability else { return nil }
        return best
    }

    func rewrite(_ text: String, instruction: String, language: String?) async throws -> String {
        throw EngineError(L("Questo modello continua il testo ma non segue istruzioni: per riscrivere scegli un modello istruito o Apple Intelligence."))
    }
}

/// Lo stato della risposta, condiviso con la funzione chiamata per ogni token (sulla coda del motore).
private final class StopBox: @unchecked Sendable {
    var stop: ConfidenceStop
    var natural = false
    init(stop: ConfidenceStop) { self.stop = stop }
}
#endif
