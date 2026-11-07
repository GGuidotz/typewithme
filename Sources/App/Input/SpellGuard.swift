// Il refuso sospetto: se la parola che stai scrivendo ha già un errore, allungarla non aiuta. Il controllo
// ortografico di macOS dice se il pezzo di parola è sbagliato e se esiste una parola che comincia così; se è sbagliato
// e nessuna parola comincia così, niente suggerimento. Guarda solo la parola corrente: non è un correttore.

import AppKit

@MainActor
enum SpellGuard {
    private static let tag = NSSpellChecker.uniqueSpellDocumentTag()

    /// Vero se `partial` (almeno 4 lettere) sembra già sbagliato. `language`: "it", "en", nil per quella di sistema.
    static func looksMistyped(_ partial: String, language: String?) -> Bool {
        guard partial.count >= 4, partial.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return false }
        if learned.contains(partial.lowercased()) { return false }
        let checker = NSSpellChecker.shared
        // Nella lingua del testo e in inglese: in una frase italiana "deploy" o "feedb" non sono refusi.
        var codes = [language ?? "it"]
        if !codes.contains("en") { codes.append("en") }
        for code in codes {
            guard let lang = checker.availableLanguages.first(where: { $0 == code || $0.hasPrefix(code + "_") }) else { continue }
            var words = 0
            let miss = checker.checkSpelling(of: partial, startingAt: 0, language: lang, wrap: false,
                                             inSpellDocumentWithTag: tag, wordCount: &words)
            if miss.location == NSNotFound { return false }   // è già una parola intera: va bene
            let range = NSRange(location: 0, length: (partial as NSString).length)
            let completions = checker.completions(forPartialWordRange: range, in: partial, language: lang,
                                                  inSpellDocumentWithTag: tag) ?? []
            if !completions.isEmpty { return false }
        }
        return true
    }

    /// Le parole che si accettano senza controllo: quelle imparate dal correttore (Ignora) e quelle dell'utente.
    static var learned: Set<String> = []

    /// Vero se `word` è una parola valida in italiano o in inglese (si scrive mescolando le due lingue: "deploy",
    /// "meeting", "feature" in una frase italiana non sono errori), o una che l'utente usa o ha detto di ignorare.
    /// Sigle, nomi con maiuscole interne, parole con cifre: sempre valide.
    static func isKnown(_ word: String) -> Bool {
        guard word.count >= 2, word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return true }
        if word.dropFirst().contains(where: \.isUppercase) { return true }
        if learned.contains(word.lowercased()) { return true }
        let checker = NSSpellChecker.shared
        for code in ["it", "en"] {
            guard let lang = checker.availableLanguages.first(where: { $0 == code || $0.hasPrefix(code + "_") }) else { continue }
            var count = 0
            let miss = checker.checkSpelling(of: word, startingAt: 0, language: lang, wrap: false,
                                             inSpellDocumentWithTag: tag, wordCount: &count)
            if miss.location == NSNotFound { return true }
        }
        return false
    }

    /// Le correzioni proposte per una parola sbagliata, nella lingua del testo prima.
    static func guesses(_ word: String, language: String?) -> [String] {
        let checker = NSSpellChecker.shared
        let codes = [language ?? "it", language == "en" ? "it" : "en"]
        for code in codes {
            guard let lang = checker.availableLanguages.first(where: { $0 == code || $0.hasPrefix(code + "_") }) else { continue }
            let range = NSRange(location: 0, length: (word as NSString).length)
            let list = checker.guesses(forWordRange: range, in: word, language: lang, inSpellDocumentWithTag: tag) ?? []
            if !list.isEmpty { return Array(list.prefix(3)) }
        }
        return []
    }
}
