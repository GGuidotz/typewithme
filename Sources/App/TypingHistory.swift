// La cronologia di scrittura: il testo che scrivi nei campi, per personalizzare i suggerimenti (si pescano pezzi tuoi
// della stessa app, simili a quello che stai scrivendo). Ogni campo ha una sessione in memoria ("pending") che cresce
// mentre scrivi; quando il campo cambia, l'app cambia o la sessione si chiude, il testo diventa una voce. Cifrata con
// AES-GCM in un file in Application Support; la chiave sta nel Portachiavi, solo su questo Mac. Mai nel registro.

import CryptoKit
import Foundation
import Security

@MainActor
final class TypingHistory: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        var id: UUID
        var bundleID: String
        var appName: String
        var date: Date
        var text: String
    }

    /// Una sessione di scrittura ancora aperta, in memoria.
    private struct Pending {
        var bundleID: String
        var appName: String
        var text: String
        var accepted: Bool
    }

    @Published private(set) var entries: [Entry] = []

    static let maxEntries = 3000
    static let maxCharacters = 1_500_000
    static let maxEntryCharacters = 1500
    static let minEntryCharacters = 20
    static let prefixMatch = 40

    private var pending: [String: Pending] = [:]
    /// Le parole significative di ogni voce, calcolate una volta sola (le voci non cambiano).
    private var wordCache: [UUID: Set<String>] = [:]
    private let url: URL
    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).history", qos: .utility)
    private var saveTask: Task<Void, Never>?

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppInfo.supportFolder, isDirectory: true)
        url = base.appendingPathComponent("history.sealed")
        SupportFiles.prepare(base)
        load()
    }

    var count: Int { entries.count }

    /// Le app con testi registrati, dalla più usata.
    var apps: [(bundleID: String, appName: String, count: Int, characters: Int)] {
        var table: [String: (name: String, count: Int, characters: Int)] = [:]
        for entry in entries {   // le voci sono in ordine di data: l'ultimo nome vince
            var row = table[entry.bundleID] ?? (entry.appName, 0, 0)
            row.name = entry.appName
            row.count += 1
            row.characters += entry.text.count
            table[entry.bundleID] = row
        }
        return table
            .map { (bundleID: $0.key, appName: $0.value.name, count: $0.value.count, characters: $0.value.characters) }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.appName.localizedCaseInsensitiveCompare(b.appName) == .orderedAscending
            }
    }

    // MARK: - Sessioni

    /// Il testo prima del cursore (fino a 2.000 caratteri) a ogni richiesta di suggerimento.
    /// `recordWithoutAccepting` decide se la sessione precedente del campo, chiusa perché il testo è cambiato del tutto,
    /// si salva anche senza suggerimenti accettati.
    func note(_ text: String, field: String, bundleID: String, appName: String, recordWithoutAccepting: Bool = true) {
        guard !text.isEmpty else { return }
        if var current = pending[field] {
            if Self.sameField(current.text, text) {
                current.text = text   // il campo sta crescendo (o il testo è stato ritoccato)
                current.bundleID = bundleID
                current.appName = appName
                pending[field] = current
                return
            }
            if recordWithoutAccepting || current.accepted { commit(current) }
        }
        pending[field] = Pending(bundleID: bundleID, appName: appName, text: text, accepted: false)
    }

    /// In questo campo è stato accettato un suggerimento.
    func markAccepted(field: String) {
        pending[field]?.accepted = true
    }

    func endSession(field: String, recordWithoutAccepting: Bool) {
        guard let current = pending.removeValue(forKey: field) else { return }
        if recordWithoutAccepting || current.accepted { commit(current) }
    }

    /// Cambio di app o chiusura dell'app: chiude tutte le sessioni.
    func endAll(recordWithoutAccepting: Bool) {
        let all = pending
        pending = [:]
        for current in all.values where recordWithoutAccepting || current.accepted { commit(current) }
    }

    /// Due testi sono lo stesso campo se iniziano allo stesso modo o uno contiene l'altro.
    private static func sameField(_ a: String, _ b: String) -> Bool {
        if a.prefix(prefixMatch) == b.prefix(prefixMatch) { return true }
        if a.contains(b) || b.contains(a) { return true }
        // Oltre i 2.000 caratteri letti l'inizio scorre: è lo stesso campo se la fine di prima è ancora nel testo.
        let tail = a.suffix(200)
        return tail.count >= 50 && b.contains(tail)
    }

    private func commit(_ current: Pending) {
        // Se salvare o no lo decidono i chiamanti; qui restano i controlli sul testo.
        let text = Self.tail(current.text, Self.maxEntryCharacters)
        guard text.reduce(0, { $0 + ($1.isWhitespace ? 0 : 1) }) >= Self.minEntryCharacters else { return }
        if let last = entries.last(where: { $0.bundleID == current.bundleID }), last.text == text { return }
        entries.append(Entry(id: UUID(), bundleID: current.bundleID, appName: current.appName, date: Date(), text: text))
        trim()
        scheduleSave()
    }

    /// Gli ultimi `limit` caratteri, con l'inizio tagliato a confine di parola.
    private static func tail(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let cut = trimmed.suffix(limit)
        // Se il taglio cade dentro una parola, quella parola spezzata si butta.
        let startsMidWord = !(trimmed[trimmed.index(cut.startIndex, offsetBy: -1)].isWhitespace) && !(cut.first?.isWhitespace ?? true)
        guard startsMidWord, let space = cut.firstIndex(where: { $0.isWhitespace }) else { return String(cut) }
        return String(cut[space...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trim() {
        var total = entries.reduce(0) { $0 + $1.text.count }
        var drop = 0
        while drop < entries.count, entries.count - drop > Self.maxEntries || total > Self.maxCharacters {
            total -= entries[drop].text.count
            drop += 1
        }
        guard drop > 0 else { return }
        for entry in entries.prefix(drop) { wordCache[entry.id] = nil }
        entries.removeFirst(drop)
    }

    // MARK: - Eliminare

    func delete(bundleID: String) {
        pending = pending.filter { $0.value.bundleID != bundleID }
        for entry in entries where entry.bundleID == bundleID { wordCache[entry.id] = nil }
        entries.removeAll { $0.bundleID == bundleID }
        scheduleSave()
    }

    func deleteAll() {
        pending = [:]
        wordCache = [:]
        entries = []
        saveTask?.cancel()
        saveTask = nil
        let target = url
        queue.async { try? FileManager.default.removeItem(at: target) }
    }

    // MARK: - Pezzi simili

    /// Fino a `count` pezzi di testo tuo, della stessa app (altrimenti di qualunque), più simili a `before`.
    func snippets(for bundleID: String, before: String, count: Int, maxLength: Int = 280) -> [String] {
        guard count > 0, !entries.isEmpty else { return [] }
        var pool = entries.filter { $0.bundleID == bundleID }
        if pool.isEmpty { pool = entries }
        let recentWords = Self.words(String(before.suffix(300)))
        guard !recentWords.isEmpty else { return [] }

        var scored: [(entry: Entry, score: Int)] = []
        for entry in pool {
            // Lo stesso campo che stai scrivendo adesso: non serve a niente riproporlo.
            if before.contains(entry.text) { continue }
            if before.count > 200, entry.text.contains(before) { continue }
            let words = cachedWords(entry)
            var score = 0
            for word in recentWords where words.contains(word) { score += 1 }
            if score > 0 { scored.append((entry, score)) }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.entry.date > b.entry.date
        }
        return scored.prefix(count).map { Self.tail($0.entry.text, maxLength) }
    }

    private func cachedWords(_ entry: Entry) -> Set<String> {
        if let known = wordCache[entry.id] { return known }
        let words = Self.words(entry.text)
        wordCache[entry.id] = words
        return words
    }

    /// Parole minuscole di almeno 4 lettere, senza punteggiatura.
    private static func words(_ text: String) -> Set<String> {
        var result = Set<String>()
        for piece in text.lowercased().split(whereSeparator: { !$0.isLetter }) where piece.count >= 4 {
            result.insert(String(piece))
        }
        return result
    }

    // MARK: - File cifrato

    private nonisolated static var keychainService: String { AppInfo.bundleID + ".history" }

    /// La chiave nel Portachiavi; con `create` la crea se manca.
    nonisolated static func key(create: Bool) -> SymmetricKey? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "key",
        ]
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard create else { return nil }
        let fresh = SymmetricKey(size: .bits256)
        let data = fresh.withUnsafeBytes { Data($0) }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // La memoria delle frasi chiede la chiave da un'altra coda: se nel frattempo l'ha creata l'altra parte, si usa
            // quella (cancellarla renderebbe illeggibile ciò che è già stato cifrato).
            var again: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &again) == errSecSuccess, let data = again as? Data, data.count == 32 {
                return SymmetricKey(data: data)
            }
            // Una voce di dimensione sbagliata: la si toglie e si riprova una volta.
            SecItemDelete(base as CFDictionary)
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess ? fresh : nil
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let sealed = try? Data(contentsOf: url),
              let key = Self.key(create: false),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key),
              let decoded = try? JSONDecoder().decode([Entry].self, from: plain) else {
            quarantine()
            diag(.app, "Typing history unreadable, starting empty")
            return
        }
        entries = decoded
        trim()
        diag(.app, "Typing history loaded: \(entries.count) entries")
    }

    /// Il file che non si apre si mette da parte e si riparte da zero.
    private func quarantine() {
        let aside = url.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.persist(wait: false)
        }
    }

    /// Scrive subito (per la chiusura dell'app). I dati si preparano qui, sul main actor; cifratura e file in coda.
    func saveNow() { persist(wait: true) }

    private func persist(wait: Bool) {
        saveTask?.cancel()
        saveTask = nil
        guard let plain = try? JSONEncoder().encode(entries), let key = Self.key(create: true) else { return }
        let target = url
        let work: @Sendable () -> Void = {
            do {
                let sealed = try AES.GCM.seal(plain, using: key).combined
                guard let sealed else { return }
                SupportFiles.prepare(target.deletingLastPathComponent())
                try sealed.write(to: target, options: .atomic)
                SupportFiles.protect(target)
            } catch {}
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }
}
