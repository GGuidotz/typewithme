// Le differenze tra un testo e la sua versione corretta, parola per parola: dove il correttore (Apple Intelligence)
// ha cambiato qualcosa, con la posizione nel testo originale in unità UTF-16 (come l'Accessibilità). L'elenco degli
// errori che dà il modello è impreciso; il confronto tra le due versioni no. Solo Foundation.

import Foundation

struct TextEdit: Equatable {
    /// La parte del testo originale da sostituire, in unità UTF-16 dall'inizio del testo.
    var range: NSRange
    var original: String
    var replacement: String
}

enum TextDiff {
    /// Un pezzo di testo: una parola (lettere, cifre, apostrofi interni), uno spazio o un segno.
    private struct Token: Equatable {
        let text: String
        let offset: Int   // UTF-16
        static func == (a: Token, b: Token) -> Bool { a.text == b.text }
    }

    private static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var current = ""
        var start = 0
        var offset = 0
        func flush() {
            if !current.isEmpty { out.append(Token(text: current, offset: start)) }
            current = ""
        }
        let characters = Array(text)
        for (i, ch) in characters.enumerated() {
            let isWordPart = ch.isLetter || ch.isNumber
                || ((ch == "'" || ch == "’") && i > 0 && characters[i - 1].isLetter
                    && i + 1 < characters.count && characters[i + 1].isLetter)
            if isWordPart {
                if current.isEmpty { start = offset }
                current.append(ch)
            } else {
                flush()
                out.append(Token(text: String(ch), offset: offset))
            }
            offset += ch.utf16.count
        }
        flush()
        return out
    }

    /// Le modifiche che portano `original` a `corrected`. Le modifiche vicine (separate solo da spazi) si uniscono:
    /// "qual'è" → "qual è" è una correzione, non tre. Vuoto se i testi coincidono o sono troppo diversi per essere una
    /// correzione (più di metà delle parole cambiate: allora il modello ha riscritto, non corretto).
    static func edits(from original: String, to corrected: String) -> [TextEdit] {
        guard original != corrected else { return [] }
        let a = tokens(original)
        let b = tokens(corrected)
        guard a.count < 2000, b.count < 2000 else { return [] }
        // Sottosequenza comune più lunga.
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var edits: [(aStart: Int, aEnd: Int, bStart: Int, bEnd: Int)] = []
        var i = 0, j = 0
        var open: (aStart: Int, bStart: Int)?
        func close() {
            if let o = open { edits.append((o.aStart, i, o.bStart, j)) }
            open = nil
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                close()
                i += 1; j += 1
            } else if j < b.count, i == a.count || table[i][j + 1] >= table[i + 1][j] {
                if open == nil { open = (i, j) }
                j += 1
            } else {
                if open == nil { open = (i, j) }
                i += 1
            }
        }
        close()
        // Unisce le modifiche separate solo da spazi.
        var merged: [(aStart: Int, aEnd: Int, bStart: Int, bEnd: Int)] = []
        for e in edits {
            if let last = merged.last, (last.aEnd..<e.aStart).allSatisfy({ a[$0].text.allSatisfy(\.isWhitespace) }),
               e.aStart - last.aEnd <= 1 {
                merged[merged.count - 1] = (last.aStart, e.aEnd, last.bStart, e.bEnd)
            } else {
                merged.append(e)
            }
        }
        let changedWords = merged.reduce(0) { sum, e in
            sum + (e.aStart..<e.aEnd).filter { a[$0].text.first?.isLetter == true }.count
        }
        let totalWords = a.filter { $0.text.first?.isLetter == true }.count
        guard totalWords == 0 || Double(changedWords) <= Double(totalWords) * 0.5 else { return [] }
        let source = original as NSString
        return merged.compactMap { e in
            // Un'inserzione pura (niente da togliere nell'originale) si aggancia al token prima, per avere un punto.
            var aStart = e.aStart, aEnd = e.aEnd, bStart = e.bStart
            if aStart == aEnd {
                guard aStart > 0 else { return nil }
                aStart -= 1
                bStart -= 1
                if bStart < 0 { return nil }
            }
            _ = aEnd
            aEnd = max(aEnd, aStart + 1)
            let location = a[aStart].offset
            let end = a[aEnd - 1].offset + a[aEnd - 1].text.utf16.count
            let range = NSRange(location: location, length: end - location)
            let replacement = b[bStart..<e.bEnd].map(\.text).joined()
            let originalText = source.substring(with: range)
            guard originalText != replacement else { return nil }
            return TextEdit(range: range, original: originalText, replacement: replacement)
        }
    }

    /// `text` con le modifiche applicate (che devono riferirsi a `text` e non sovrapporsi).
    static func apply(_ edits: [TextEdit], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard NSMaxRange(edit.range) <= result.length else { continue }
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }
}
