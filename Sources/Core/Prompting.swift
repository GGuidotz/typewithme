// Cosa si dice al modello e come si pulisce quello che risponde. Le istruzioni sono in inglese perché i modelli
// piccoli le seguono meglio; il testo da continuare resta nella sua lingua e il modello deve rispondere in quella.
// Istruzioni corte: ogni riga in più costa tempo al modello di Apple, che ha anche una finestra piccola (circa 4.000
// token); il contesto lo taglia ogni motore (CompletionEngine.contextLimit). Mentre il modello scrive, il seguito a
// metà si pulisce senza tagliarlo a fine frase (cleanCompletion con final: false).

import Foundation

enum Prompting {
    // MARK: - Completamento

    static func completionInstructions(_ r: CompletionRequest) -> String {
        var lines = [
            "You are an autocomplete engine. Write ONLY the text that comes next at the cursor.",
            "- No quotes, labels, explanations, markdown or emoji. Never repeat the text before the cursor.",
            "- Same language as the text (\(languageName(r.language))), same tone.",
            "- Length: \(lengthHint(r.length, words: r.maxWords)). Stop at the end of the sentence.",
            "- Mid-word: finish the word, then go on. After a space: start with the next word. After a complete word or punctuation: start with a space.",
            "- If nothing fits, output nothing.",
        ]
        if !r.context.after.isEmpty {
            lines.append("- Text follows the cursor on the same line: join it smoothly, do not repeat it.")
        }
        if r.clipboard != nil {
            lines.append("- Use the clipboard only if it clearly helps (names, numbers, addresses).")
        }
        if r.screen != nil || r.windowTitle != nil {
            lines.append("- The window text shows what the user is replying to or looking at (a message, a chat, a page): continue as a reply in that conversation, with its names, facts, dates and topic. Never copy it blindly.")
        }
        if !r.ownWriting.isEmpty {
            lines.append("- Earlier texts by the user are given: prefer their words, phrases and style.")
        }
        let own = r.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty {
            lines.append("User preferences: \(own)")
        }
        let forApp = r.appInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !forApp.isEmpty {
            lines.append("Preferences for this app: \(forApp)")
        }
        return lines.joined(separator: "\n")
    }

    static func completionPrompt(_ r: CompletionRequest) -> String {
        // Prima ciò che cambia di rado (app, scritti tuoi, schermo, appunti), poi il testo: così l'inizio del prompt
        // resta uguale tra una richiesta e l'altra e llama.cpp lo riprende dalla cache.
        var out = "App: \(r.context.appName.isEmpty ? "unknown" : r.context.appName)\n"
        if let title = r.windowTitle { out += "Window: \(String(title.prefix(120)))\n" }
        for (i, own) in r.ownWriting.enumerated() {
            out += "Earlier text by the user (\(i + 1)):\n«\(own)»\n"
        }
        if let screen = r.screen, !screen.isEmpty {
            out += "Text in the window:\n«\(String(screen.prefix(Self.maxScreen)))»\n"
        }
        if let clip = r.clipboard, !clip.isEmpty {
            out += "Clipboard:\n«\(String(clip.prefix(500)))»\n"
        }
        out += "Text before the cursor:\n«\(r.context.before)»\n"
        if !r.context.after.isEmpty {
            out += "Text after the cursor on the same line:\n«\(r.context.after)»\n"
        }
        if r.context.before.last?.isWhitespace == true {
            out += "The text ends with a space. Continue with the next word."
        } else if r.context.partialWord.isEmpty {
            out += "The text ends right after a complete word or punctuation. Start with a space."
        } else {
            out += "The text ends in the middle of the word \"\(r.context.partialWord)\". Complete it, then continue."
        }
        return out
    }

    /// Caratteri al massimo del testo dello schermo nel prompt.
    static let maxScreen = 800

    /// Il prompt per un modello base, che non segue istruzioni ma continua un documento. Fino alla 0.3.0 c'era
    /// un'intestazione con istruzioni in inglese, testi tuoi, schermo e appunti: un modello da 1B la prendeva per il
    /// documento da continuare (scriveva "---", etichette, pezzi di pulsanti). Ora il contesto ha la forma di un
    /// documento vero, quella che il modello ha visto mille volte: in una mail l'oggetto e il messaggio a cui rispondi,
    /// citato con "> "; in una chat gli ultimi messaggi, una riga ciascuno. Solo righe di testo scritto (niente menu,
    /// pulsanti, orari) e al massimo `maxDocumentContext` caratteri. Senza contesto, il testo prima del cursore e basta.
    /// Il contesto resta fermo per tutto il campo (Completer.windowContext): il prompt cresce solo in coda e resta
    /// nella cache.
    static func rawPrompt(_ r: CompletionRequest) -> String {
        let head = documentContext(r)
        return head.isEmpty ? r.context.before : head + "\n\n" + r.context.before
    }

    /// Caratteri al massimo del contesto davanti al testo, per un modello base.
    static let maxDocumentContext = 800

    enum AppKind { case mail, chat, other }

    static func appKind(_ bundleID: String) -> AppKind {
        let id = bundleID.lowercased()
        let mail = ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail", "com.superhuman", "it.bloop.airmail",
                    "com.mimestream", "com.google.gmail"]
        let chat = ["com.apple.mobilesms", "net.whatsapp", "desktop.whatsapp", "com.tinyspeck.slackmacgap", "ru.keepcoder.telegram",
                    "org.telegram", "com.hnc.discord", "org.whispersystems.signal", "com.microsoft.teams", "com.facebook.archon",
                    "com.anthropic.claudefordesktop", "com.openai.chat"]
        if mail.contains(where: { id.hasPrefix($0) }) { return .mail }
        if chat.contains(where: { id.hasPrefix($0) }) { return .chat }
        return .other
    }

    static func documentContext(_ r: CompletionRequest) -> String {
        let kind = appKind(r.context.bundleID)
        let italian = (r.language ?? "it") == "it"
        var source = [r.quoted, r.screen].compactMap { $0 }.joined(separator: "\n")
        source = String(source.prefix(4000))
        var lines = proseLines(source)
        // Il pezzo più vicino a quello che scrivi: in una chat gli ultimi messaggi, in una mail citata l'inizio.
        var budget = maxDocumentContext
        var kept: [String] = []
        let ordered = r.quoted != nil && kind == .mail ? lines : Array(lines.reversed())
        for line in ordered {
            let piece = String(line.prefix(300))
            guard budget - piece.count > 0 else { break }
            kept.append(piece)
            budget -= piece.count + 1
        }
        if !(r.quoted != nil && kind == .mail) { kept.reverse() }
        lines = kept
        var out = ""
        switch kind {
        case .mail:
            if let title = r.windowTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
                out += (italian ? "Oggetto: " : "Subject: ") + String(title.prefix(120)) + "\n"
            }
            if !lines.isEmpty { out += (out.isEmpty ? "" : "\n") + lines.map { "> " + $0 }.joined(separator: "\n") }
        case .chat, .other:
            out = lines.joined(separator: "\n")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Le righe che sembrano testo scritto: almeno tre parole, quasi tutte lettere, senza indirizzi web.
    static func proseLines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isNewline }).compactMap { raw in
            let line = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let words = line.split(separator: " ").filter { $0.contains(where: { $0.isLetter }) }
            guard words.count >= 3, !line.contains("://"), !line.contains("www.") else { return nil }
            let visible = line.filter { !$0.isWhitespace }
            let letters = visible.filter { $0.isLetter }.count
            guard !visible.isEmpty, Double(letters) / Double(visible.count) >= 0.75 else { return nil }
            return line
        }
    }

    private static let labels = ["Continuation:", "Completion:", "Output:", "Text:"]

    /// Dalla risposta grezza al seguito da mostrare: via virgolette, ripetizioni, emoji e a capo; taglio a fine frase e
    /// al numero di parole scelto; spazio iniziale giusto. nil se non resta niente di utile.
    /// Con `final` falso il testo è ancora a metà (il modello sta scrivendo): niente taglio a fine frase, e un'etichetta
    /// o una virgoletta aperta non ancora chiusa non si mostrano.
    static func cleanCompletion(_ raw: String, for r: CompletionRequest, final: Bool = true) -> String? {
        var text = raw
        text = text.replacingOccurrences(of: "```", with: "")
        text = TextTokens.removingEmoji(text)
        // Il modello a volte etichetta la risposta.
        for label in labels where text.trimmingCharacters(in: .whitespaces).hasPrefix(label) {
            text = String(text.trimmingCharacters(in: .whitespaces).dropFirst(label.count))
        }
        if !final {
            // Un'etichetta che sta ancora arrivando ("Contin…"): meglio aspettare il pezzo dopo.
            let head = text.trimmingCharacters(in: .whitespaces)
            if !head.isEmpty, labels.contains(where: { $0.hasPrefix(head) }) { return nil }
        }
        // Virgolette intorno a tutto.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("«", "»"), ("\"", "\""), ("“", "”"), ("'", "'")] where trimmed.hasPrefix(open) && trimmed.hasSuffix(close) && trimmed.count > 2 {
            text = String(trimmed.dropFirst().dropLast())
        }
        if !final {
            // A metà la virgoletta di chiusura non è ancora arrivata: via quella d'apertura.
            let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = head.first, first == "«" || first == "\"" || first == "“" {
                text = String(head.dropFirst())
            }
        }
        // Un solo rigo: gli a capo diventano spazi, e si prende al massimo il numero di frasi scelto.
        text = text.replacingOccurrences(of: "\r", with: "")
        if let newline = text.firstIndex(of: "\n") {
            let firstLine = text[..<newline].trimmingCharacters(in: .whitespaces)
            if firstLine.isEmpty {
                // Il modello è andato a capo: la riga dopo vale solo se comincia con una parola (non "1.", "-", "*").
                let next = (String(text[text.index(after: newline)...]).components(separatedBy: "\n").first ?? "")
                    .trimmingCharacters(in: .whitespaces)
                guard next.first?.isLetter == true else { return nil }
                text = next
            } else {
                text = String(firstLine)
            }
        }
        text = collapseSpaces(text)
        // Un modello base ha letto molte pagine web: a volte continua con tag HTML o grassetto markdown. Il seguito
        // finisce lì, a meno che tu non stia scrivendo proprio HTML o markdown.
        text = cuttingMarkup(text, before: r.context.before)

        // Se ripete la fine del testo già scritto, via la parte ripetuta.
        text = removingOverlap(text, before: r.context.before)
        // Se finisce ripetendo l'inizio del testo che segue, via anche quello.
        if !r.context.after.isEmpty { text = removingTrailingOverlap(text, after: r.context.after) }

        // Spazio iniziale: giusto rispetto a ciò che precede.
        let before = r.context.before
        if before.last?.isWhitespace == true || before.isEmpty {
            text = String(text.drop(while: { $0 == " " }))
        } else if r.context.partialWord.isEmpty, let first = text.first, first.isLetter || first.isNumber {
            text = " " + text
        }
        // Mai due spazi tra prima e dopo.
        if before.last == " ", text.first == " " { text = String(text.dropFirst()) }

        // Taglio a fine frase (solo a risposta finita) e a numero di parole.
        if final { text = cutToSentences(text, max: r.length.maxSentences) }
        text = cutToWords(text, max: r.maxWords)
        text = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        // Il seguito deve legarsi bene a ciò che viene dopo sulla riga.
        if final, let next = r.context.after.first, !next.isWhitespace, !next.isPunctuation, text.last?.isLetter == true {
            text += " "
        }
        let meaningful = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !meaningful.isEmpty, meaningful != "\"\"" else { return nil }
        // Solo cifre o punteggiatura ("1", ".", "..."): non è un seguito, a meno di stare completando un numero.
        let completingNumber = r.context.partialWord.last?.isNumber == true
        if !completingNumber, !meaningful.contains(where: { $0.isLetter }) { return nil }
        return text
    }

    // MARK: - Riscrittura

    static func rewriteInstructions(_ instruction: String, language: String?) -> String {
        """
        You rewrite text for the user. \(instruction)
        Rules: answer with the rewritten text only, in the same language as the original (\(languageName(language))). \
        No quotes, no preamble, no explanation, no markdown, no emoji. Keep line breaks and paragraphs where the original has them. \
        Never add information that is not in the original.
        """
    }

    static func rewritePrompt(_ text: String) -> String {
        "Original text:\n«\(text)»\n\nRewritten text:"
    }

    static func cleanRewrite(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "```", with: "")
        text = TextTokens.removingEmoji(text).trimmingCharacters(in: .whitespacesAndNewlines)
        for label in ["Rewritten text:", "Rewritten:", "Output:"] where text.hasPrefix(label) {
            text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (open, close) in [("«", "»"), ("\"", "\""), ("“", "”")] where text.hasPrefix(open) && text.hasSuffix(close) && text.count > 2 {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    // MARK: - Pezzi

    static func languageName(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "the language of the text" }
        switch code {
        case "it": return "Italian"
        case "en": return "English"
        case "fr": return "French"
        case "de": return "German"
        case "es": return "Spanish"
        case "pt": return "Portuguese"
        default: return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "the language of the text"
        }
    }

    private static func lengthHint(_ length: SuggestionLength, words: Int) -> String {
        switch length {
        case .word: "only finish the word being typed, never add another word"
        case .short: "very short: a few words, at most \(words)"
        case .medium: "short: one sentence, at most \(words) words"
        case .long: "at most two sentences, at most \(words) words"
        }
    }

    /// Il seguito fino al primo tag (`<strong>`, `</p>`, `<br/>`) o al primo `**`, se il testo prima del cursore non
    /// ne contiene: "e poi <strong>domani" → "e poi".
    static func cuttingMarkup(_ text: String, before: String) -> String {
        var cut = text.endIndex
        if !before.contains("<"), let tag = text.range(of: "</?[A-Za-z][A-Za-z0-9]*", options: .regularExpression) {
            cut = tag.lowerBound
        }
        if !before.contains("**"), let bold = text.range(of: "**"), bold.lowerBound < cut {
            cut = bold.lowerBound
        }
        guard cut < text.endIndex else { return text }
        return String(text[..<cut]).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    static func collapseSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
    }

    /// "…come stai" + risposta "come stai oggi?" → " oggi?": via la parte che ripete la coda del testo scritto.
    static func removingOverlap(_ completion: String, before: String) -> String {
        let tail = String(before.suffix(120)).lowercased()
        let comp = completion.lowercased()
        let compLeading = comp.drop(while: { $0 == " " })
        let leading = comp.count - compLeading.count
        // Il più lungo suffisso di `tail` che è prefisso della risposta (senza gli spazi iniziali), a confine di parola.
        var best = 0
        let tailChars = Array(tail), compChars = Array(compLeading)
        let maxLen = min(tailChars.count, compChars.count)
        if maxLen > 0 {
            for len in stride(from: maxLen, through: 3, by: -1) {
                if Array(tailChars.suffix(len)) == Array(compChars.prefix(len)) {
                    let startsAtBoundary = len == tailChars.count || !(tailChars[tailChars.count - len - 1].isLetter)
                    let endsAtBoundary = len == compChars.count || !(compChars[len].isLetter)
                    if startsAtBoundary && endsAtBoundary { best = len; break }
                }
            }
        }
        guard best > 0 else { return completion }
        return String(completion.dropFirst(leading + best))
    }

    static func removingTrailingOverlap(_ completion: String, after: String) -> String {
        let head = String(after.prefix(80)).lowercased().trimmingCharacters(in: .whitespaces)
        let comp = completion.lowercased()
        guard !head.isEmpty else { return completion }
        let compChars = Array(comp), headChars = Array(head)
        for len in stride(from: min(compChars.count, headChars.count), through: 3, by: -1) {
            if Array(compChars.suffix(len)) == Array(headChars.prefix(len)) {
                return String(completion.dropLast(len)).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }
        }
        return completion
    }

    /// Tiene al massimo `max` frasi: taglia dopo il punto, il punto interrogativo o esclamativo seguito da spazio.
    static func cutToSentences(_ text: String, max: Int) -> String {
        var count = 0
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "." || ch == "!" || ch == "?" {
                var next = text.index(after: index)
                while next < text.endIndex, text[next] == "." || text[next] == "!" || text[next] == "?" || text[next] == "\"" || text[next] == "»" || text[next] == ")" {
                    next = text.index(after: next)
                }
                if next == text.endIndex || text[next].isWhitespace {
                    count += 1
                    if count >= max { return String(text[..<next]) }
                }
                index = next
            } else {
                index = text.index(after: index)
            }
        }
        return text
    }

    /// Tiene al massimo `max` parole, chiudendo dove possibile su una virgola o fine frase.
    static func cutToWords(_ text: String, max: Int) -> String {
        let words = TextTokens.words(withLeadingSpace: text)
        guard words.count > max else { return text }
        var kept = Array(words.prefix(max))
        // Meglio fermarsi su una virgola o un punto negli ultimi pezzi, se c'è.
        let closers: Set<Character> = [",", ".", ";", ":", "!", "?"]
        if let i = kept.lastIndex(where: { word in word.last.map { closers.contains($0) } == true }), i >= max / 2 {
            kept = Array(kept.prefix(i + 1))
        }
        return kept.joined()
    }
}
