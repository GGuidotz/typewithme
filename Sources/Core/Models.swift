// I tipi che girano tra lettura del campo, motori e interfaccia. Solo Foundation.

import Foundation

/// Il testo intorno al cursore nel campo che ha il fuoco, più chi lo ospita.
struct TextContext: Equatable {
    /// Gli ultimi caratteri prima del cursore (al massimo `TextContext.maxBefore`).
    var before: String
    /// Il testo dopo il cursore sulla stessa riga; vuoto se il cursore è in fondo o il completamento a metà riga è spento.
    var after: String = ""
    var appName: String = ""
    var bundleID: String = ""

    static let maxBefore = 2000
    static let maxAfter = 200

    /// Vero se il cursore è subito dopo uno spazio, un a capo o un segno di punteggiatura.
    var endsAtWordBoundary: Bool {
        guard let last = before.unicodeScalars.last else { return true }
        return !CharacterSet.alphanumerics.contains(last) && last != "'" && last != "’"
    }

    /// La parola che si sta ancora scrivendo (lettere subito prima del cursore), vuota a fine parola.
    var partialWord: String {
        var out = ""
        for scalar in before.unicodeScalars.reversed() {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "’" {
                out.unicodeScalars.insert(scalar, at: out.unicodeScalars.startIndex)
            } else {
                break
            }
        }
        return out
    }

    /// Lo stesso contesto con al massimo `max` caratteri prima del cursore, tagliato a confine di parola: i modelli
    /// piccoli rispondono prima e meglio con meno testo.
    func limited(to max: Int) -> TextContext {
        guard max > 0, before.count > max else { return self }
        var cut = String(before.suffix(max))
        // Se il taglio cade a metà di una parola, via quel pezzo di parola.
        let droppedLast = before.dropLast(max).last
        let atBoundary = droppedLast.map { $0.isWhitespace || $0.isNewline } ?? true
        if !atBoundary, let space = cut.firstIndex(where: { $0.isWhitespace || $0.isNewline }) {
            let rest = cut[cut.index(after: space)...]
            if !rest.isEmpty { cut = String(rest) }
        }
        var copy = self
        copy.before = cut
        return copy
    }

    /// Come `limited(to:)`, ma con l'inizio ancorato a posizioni fisse del documento (multipli di `step`, in unità
    /// UTF-16 come il cursore): mentre scrivi l'inizio del testo mandato al modello resta lo stesso per centinaia di
    /// tasti, così llama.cpp riusa il prompt già elaborato invece di rifarlo a ogni richiesta. Tra `max - step` e
    /// `max` unità. `caret` è la posizione del cursore nel campo; `before` deve finire lì.
    func anchored(caret: Int, max: Int, step: Int = 256) -> TextContext {
        let units = before.utf16
        guard max > step, step > 0, caret >= units.count, units.count > max - step else { return self }
        let readStart = caret - units.count
        // Il primo multiplo di `step` da cui restano al massimo `max` unità fino al cursore.
        let lowest = caret - max
        let anchor = lowest <= 0 ? 0 : ((lowest + step - 1) / step) * step
        let drop = anchor - readStart
        guard drop > 0 else { return self }
        var index = units.index(units.startIndex, offsetBy: drop)
        // Mai a metà di un carattere fatto di due unità.
        while index < units.endIndex, String.Index(index, within: before) == nil { index = units.index(after: index) }
        guard let start = String.Index(index, within: before) else { return self }
        var cut = String(before[start...])
        // Via il pezzo di parola tagliato all'inizio (deterministico: stesso inizio, stesso taglio).
        let previous = before[..<start].last
        let atBoundary = previous.map { $0.isWhitespace || $0.isNewline } ?? true
        if !atBoundary, let space = cut.firstIndex(where: { $0.isWhitespace || $0.isNewline }) {
            let rest = cut[cut.index(after: space)...]
            if !rest.isEmpty { cut = String(rest) }
        }
        var copy = self
        copy.before = cut
        return copy
    }
}

/// Quanto lungo deve essere un suggerimento.
enum SuggestionLength: String, CaseIterable, Codable, Identifiable {
    /// Solo la parola che stai scrivendo: aiuto all'ortografia, mai la parola dopo.
    case word, short, medium, long
    var id: String { rawValue }

    var title: String {
        switch self {
        case .word: L("Parola")
        case .short: L("Breve")
        case .medium: L("Media")
        case .long: L("Lunga")
        }
    }

    var detail: String {
        switch self {
        case .word: L("Solo la parola che stai scrivendo, mai quella dopo.")
        case .short: L("Poche parole, fino a fine frase.")
        case .medium: L("Una frase intera.")
        case .long: L("Fino a due frasi.")
        }
    }

    /// Parole al massimo nel suggerimento mostrato.
    var maxWords: Int {
        switch self {
        case .word: 1
        case .short: 6
        case .medium: 14
        case .long: 30
        }
    }

    /// Frasi al massimo: oltre, il testo si taglia.
    var maxSentences: Int { self == .long ? 2 : 1 }

    /// Token da chiedere al modello (un po' più delle parole, per la punteggiatura).
    var maxTokens: Int { maxWords * 2 + 8 }

    /// Parole al massimo scelte con lo slider (1...maxSlider).
    static let maxSlider = 20

    /// Lo stile che va con un numero massimo di parole: 1 è solo la parola in corso, poi breve, media, lunga.
    static func forWords(_ words: Int) -> SuggestionLength {
        switch words {
        case ...1: .word
        case 2...6: .short
        case 7...14: .medium
        default: .long
        }
    }
}

/// Tutto ciò che serve a un motore per proporre il seguito.
struct CompletionRequest {
    var context: TextContext
    var length: SuggestionLength
    /// Codice della lingua riconosciuta nel testo ("it", "en"), nil se non si capisce.
    var language: String?
    /// Le istruzioni di chi usa l'app (tono, stile), vuote se non ne ha scritte.
    var instructions: String = ""
    /// Le istruzioni per l'app in cui si scrive (Impostazioni › App), vuote se non ce ne sono.
    var appInstructions: String = ""
    /// Gli appunti, se l'utente ha scelto di usarli come contesto.
    var clipboard: String?
    /// Il testo riconosciuto nella finestra in primo piano (Contesto dallo schermo), se acceso.
    var screen: String?
    /// Pezzi di testo scritti prima da chi usa l'app, nella stessa app (Personalizzazione), per imitarne le parole.
    var ownWriting: [String] = []
    /// Parole al massimo scelte con lo slider; 0: quelle della lunghezza.
    var wordLimit: Int = 0
    /// Il titolo della finestra in cui si scrive (oggetto della mail, nome del documento, chat), se Contesto dall'app.
    var windowTitle: String?
    /// Il messaggio a cui rispondi, quando sta nello stesso campo sotto il cursore (la mail citata in una risposta).
    var quoted: String?
    /// Le parole che di solito scrivi qui secondo il modello personale, e quanto contano (0: niente, 1: solo loro).
    var personal: [PersonalCandidate] = []
    var personalWeight: Double = 0

    var maxWords: Int { wordLimit > 0 ? wordLimit : length.maxWords }
    var maxTokens: Int { maxWords * 2 + 8 }
}

enum SuggestionSource: String {
    case memory, rules, apple, gemma
}

/// Un seguito proposto: il testo che manca dopo il cursore, spazi iniziali compresi.
struct Suggestion: Equatable {
    var text: String
    var source: SuggestionSource

    /// Le parole con il loro spazio davanti: " ciao," " come" " stai".
    var words: [String] { TextTokens.words(withLeadingSpace: text) }

    /// La prima parola e il resto.
    func split() -> (first: String, rest: String) {
        let parts = words
        guard let first = parts.first else { return ("", "") }
        return (first, String(text.dropFirst(first.count)))
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Cosa ha chiesto l'utente a "Riscrivi la selezione".
enum RewritePreset: String, CaseIterable, Identifiable {
    case shorter, formal, casual, fix
    var id: String { rawValue }

    var title: String {
        switch self {
        case .shorter: L("Più breve")
        case .formal: L("Più formale")
        case .casual: L("Più informale")
        case .fix: L("Correggi")
        }
    }

    var symbol: String {
        switch self {
        case .shorter: "arrow.down.right.and.arrow.up.left"
        case .formal: "briefcase"
        case .casual: "hand.wave"
        case .fix: "checkmark.circle"
        }
    }

    /// L'istruzione per il modello, in inglese (il modello la capisce meglio); il testo resta nella sua lingua.
    var instruction: String {
        switch self {
        case .shorter: "Rewrite the text so it is noticeably shorter, keeping every piece of information and the same tone."
        case .formal: "Rewrite the text in a more formal, professional register, keeping the meaning."
        case .casual: "Rewrite the text in a more relaxed, friendly register, keeping the meaning."
        case .fix: "Correct spelling, grammar, accents and punctuation. Change nothing else: same words, same order, same tone."
        }
    }
}

/// Pezzi di testo: parole con lo spazio davanti, ultime parole, confini.
enum TextTokens {
    /// " ciao, come stai" → [" ciao,", " come", " stai"]. Ogni pezzo porta con sé gli spazi che lo precedono.
    static func words(withLeadingSpace text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inWord = false
        for ch in text {
            if ch.isWhitespace || ch.isNewline {
                if inWord {
                    out.append(current)
                    current = ""
                    inWord = false
                }
                current.append(ch)
            } else {
                current.append(ch)
                inWord = true
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Le ultime `n` parole, senza punteggiatura intorno e in minuscolo: la chiave della memoria delle frasi.
    static func lastWords(_ text: String, _ n: Int) -> [String] {
        let pieces = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return pieces.suffix(n).map { normalized(String($0)) }.filter { !$0.isEmpty }
    }

    static func normalized(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).lowercased()
    }

    /// Quante parole ci sono.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Via tutto ciò che è un'emoji (l'app non ne scrive).
    static func removingEmoji(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            let p = s.properties
            let isEmoji = p.isEmojiPresentation || (p.isEmoji && s.value > 0x238C) || (0x1F000...0x1FAFF).contains(s.value)
                || (0xFE00...0xFE0F).contains(s.value) || s.value == 0x200D
            if !isEmoji { out.append(s) }
        }
        return String(out)
    }
}
