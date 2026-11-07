// Il modello personale: impara dai tuoi testi (la cronologia di scrittura, cifrata sul Mac) quali parole scrivi di
// solito dopo le una o due che le precedono, e quali parole usi per finire quelle che hai cominciato. Non riaddestra
// Gemma: ne riordina il seguito. Prima di scrivere, si guardano le parole più probabili per Gemma; se una parola tua
// ha un punteggio misto (Gemma e modello personale) più alto di quella che Gemma sceglierebbe, il seguito parte da
// quella. Il peso del modello personale lo decide "Scelta delle parole". Solo in memoria, solo Foundation.

import Foundation

/// Una parola che di solito scrivi in questo punto, con la sua probabilità secondo i tuoi testi.
struct PersonalCandidate: Equatable, Sendable {
    /// La parola intera come la scrivi di solito (maiuscole comprese).
    var word: String
    var probability: Double
}

struct PersonalModel {
    private var unigrams: [String: Int] = [:]
    private var bigrams: [String: [String: Int]] = [:]
    private var trigrams: [String: [String: Int]] = [:]
    /// La forma più recente di ogni parola (per le maiuscole): "luca" → "Luca".
    private var forms: [String: String] = [:]
    /// Testi imparati.
    private(set) var texts = 0
    /// Parole diverse conosciute.
    var vocabulary: Int { unigrams.count }

    /// Quante volte almeno deve comparire un seguito perché valga.
    static let minimumCount = 2

    mutating func learn(_ text: String) {
        texts += 1
        for sentence in Self.sentences(text) {
            let words = Self.words(sentence)
            for (i, word) in words.enumerated() {
                let key = word.lowercased()
                unigrams[key, default: 0] += 1
                forms[key] = word
                if i >= 1 { bigrams[words[i - 1].lowercased(), default: [:]][key, default: 0] += 1 }
                if i >= 2 {
                    trigrams[words[i - 2].lowercased() + " " + words[i - 1].lowercased(), default: [:]][key, default: 0] += 1
                }
            }
        }
    }

    /// Le parole che di solito scrivi dopo `before` (il testo fino al cursore, parola a metà compresa), le più
    /// probabili prima. A metà parola, solo quelle che cominciano così e sono più lunghe.
    func candidates(before: String, max: Int = 3) -> [PersonalCandidate] {
        let sentence = Self.sentences(before).last ?? ""
        let endsInWord = before.last.map { Self.isWordCharacter($0) } ?? false
        var words = Self.words(endsInWord ? sentence : sentence + " ")
        // Il testo finisce con un segno che chiude la frase: niente parole prima.
        if let last = before.last, ".!?\n".contains(last) { words = [] }
        let partial = endsInWord ? (words.popLast() ?? "") : ""
        let previous = words.suffix(2).map { $0.lowercased() }

        var table: [String: Int] = [:]
        if previous.count == 2, let next = trigrams[previous.joined(separator: " ")], next.values.reduce(0, +) >= Self.minimumCount {
            table = next
        } else if let last = previous.last, let next = bigrams[last], next.values.reduce(0, +) >= Self.minimumCount + 1 {
            table = next
        } else if partial.count >= 3 {
            table = unigrams
        } else {
            return []
        }
        let lowerPartial = partial.lowercased()
        let matching = table.filter { $0.key.hasPrefix(lowerPartial) && $0.key.count > lowerPartial.count }
        let total = Double(matching.values.reduce(0, +))
        guard total > 0 else { return [] }
        return matching
            .filter { $0.value >= Self.minimumCount }
            .sorted { $0.value > $1.value }
            .prefix(max)
            .map { key, count in
                var word = forms[key] ?? key
                // La maiuscola iniziale di quello che stai scrivendo vince su quella imparata.
                if let first = partial.first, first.isUppercase, let head = word.first {
                    word = head.uppercased() + word.dropFirst()
                }
                return PersonalCandidate(word: word, probability: Double(count) / total)
            }
    }

    // MARK: - Pezzi

    static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "’"
    }

    /// Le parole: lettere, cifre e apostrofi ("dell'anno" è una parola sola).
    static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for c in text {
            if isWordCharacter(c) { current.append(c) } else if !current.isEmpty { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Le frasi: si spezza a punto, punto esclamativo o interrogativo e a capo.
    static func sentences(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { ".!?\n".contains($0) }).map(String.init)
    }
}
