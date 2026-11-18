// La memoria delle frasi: i seguiti che accetti, legati alle due parole che li precedono. Quando le stesse due parole
// tornano, il seguito si propone subito, senza modello. Si impara solo dopo averlo accettato almeno due volte, così un
// seguito preso una volta per sbaglio non torna. Un file cifrato in Application Support (la cifratura la dà chi crea la
// memoria, con la chiave nel Portachiavi: qui solo Foundation), cancellabile con "Dimentica tutto". Senza cifratura la
// memoria resta in RAM e non si scrive mai in chiaro. Mai sincronizzato, mai inviato: resta sul Mac.

import Foundation

final class PhraseMemory {
    struct Entry: Codable {
        var count: Int
        var last: Date
    }

    /// chiave "parola1 parola2" → seguito → conteggio
    private var table: [String: [String: Entry]] = [:]
    private let url: URL
    /// Il vecchio file in chiaro (fino alla 0.5.5): si legge una volta, si riscrive cifrato e si cancella.
    private let legacyURL: URL
    private let seal: (@Sendable (Data) -> Data?)?
    private let unseal: (@Sendable (Data) -> Data?)?
    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).phrases", qos: .utility)
    private var saveScheduled = false

    static let minCount = 2
    static let maxKeys = 3000
    static let keyWords = 2
    static let maxContinuationWords = 8

    /// `seal` cifra e `unseal` decifra (nil se non riesce, per esempio senza chiave). Senza `seal` non si scrive niente.
    init(directory: URL? = nil, seal: (@Sendable (Data) -> Data?)? = nil, unseal: (@Sendable (Data) -> Data?)? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppInfo.supportFolder, isDirectory: true)
        url = base.appendingPathComponent("phrases.bin")
        legacyURL = base.appendingPathComponent("phrases.json")
        self.seal = seal
        self.unseal = unseal
        SupportFiles.prepare(base)
        load()
    }

    var count: Int { table.values.reduce(0) { $0 + $1.count } }

    /// Il seguito ricordato per il testo prima del cursore, se c'è ed è stato accettato abbastanza volte.
    func suggestion(before text: String) -> String? {
        guard text.last?.isWhitespace == true || text.last.map({ !$0.isLetter && !$0.isNumber }) == true else { return nil }
        let words = TextTokens.lastWords(text, Self.keyWords)
        guard words.count == Self.keyWords else { return nil }
        guard let candidates = table[words.joined(separator: " ")] else { return nil }
        var bestText: String?
        var bestEntry: Entry?
        for (continuation, entry) in candidates where entry.count >= Self.minCount {
            guard let current = bestEntry else { bestText = continuation; bestEntry = entry; continue }
            let better = entry.count > current.count || (entry.count == current.count && entry.last > current.last)
            if better { bestText = continuation; bestEntry = entry }
        }
        guard let bestText else { return nil }
        // Il seguito è salvato con lo spazio iniziale; se il testo finisce già con uno spazio, lo si toglie.
        if text.last?.isWhitespace == true { return String(bestText.drop(while: { $0 == " " })) }
        return bestText
    }

    /// Impara un seguito accettato dopo `text`.
    func learn(before text: String, accepted: String) {
        let words = TextTokens.lastWords(text, Self.keyWords)
        guard words.count == Self.keyWords else { return }
        var continuation = accepted
        let pieces = TextTokens.words(withLeadingSpace: continuation)
        if pieces.count > Self.maxContinuationWords { continuation = pieces.prefix(Self.maxContinuationWords).joined() }
        continuation = continuation.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        if !continuation.hasPrefix(" ") { continuation = " " + continuation }
        guard TextTokens.wordCount(continuation) >= 1 else { return }
        let key = words.joined(separator: " ")
        var entry = table[key]?[continuation] ?? Entry(count: 0, last: Date())
        entry.count += 1
        entry.last = Date()
        table[key, default: [:]][continuation] = entry
        prune()
        scheduleSave()
    }

    func forgetAll() {
        table = [:]
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: legacyURL)
    }

    // MARK: - File

    private func load() {
        if let sealed = try? Data(contentsOf: url) {
            if let unseal, let data = unseal(sealed),
               let decoded = try? JSONDecoder().decode([String: [String: Entry]].self, from: data) { table = decoded }
            return
        }
        // Migrazione dal file in chiaro: si legge e si riscrive cifrato (write lo cancella a cifratura riuscita).
        guard let data = try? Data(contentsOf: legacyURL),
              let decoded = try? JSONDecoder().decode([String: [String: Entry]].self, from: data) else { return }
        table = decoded
        scheduleSave()
    }

    private func prune() {
        guard table.count > Self.maxKeys else { return }
        // Via le chiavi meno usate e più vecchie.
        struct Rank { let key: String; let count: Int; let last: Date }
        var ranked: [Rank] = []
        for (key, continuations) in table {
            var count = 0
            var last = Date.distantPast
            for entry in continuations.values {
                count += entry.count
                if entry.last > last { last = entry.last }
            }
            ranked.append(Rank(key: key, count: count, last: last))
        }
        ranked.sort { a, b in
            if a.count != b.count { return a.count < b.count }
            return a.last < b.last
        }
        for rank in ranked.prefix(table.count - Self.maxKeys) { table[rank.key] = nil }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        let snapshot = table
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.write(snapshot)
            DispatchQueue.main.async { self?.saveScheduled = false }
        }
    }

    private func write(_ snapshot: [String: [String: Entry]]) {
        // Senza cifratura (o senza chiave) niente su disco: mai in chiaro.
        guard let seal else { return }
        do {
            SupportFiles.prepare(url.deletingLastPathComponent())
            let data = try JSONEncoder().encode(snapshot)
            guard let sealed = seal(data) else { return }
            try sealed.write(to: url, options: .atomic)
            SupportFiles.protect(url)
            try? FileManager.default.removeItem(at: legacyURL)
        } catch {
            // Niente da fare: la memoria resta in RAM fino alla prossima volta.
        }
    }
}
