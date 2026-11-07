// La lunghezza del seguito decisa dal modello, non da un numero fisso di parole: si va avanti finché il modello è
// sicuro di quello che scrive, misurato come media dei logprob per token (la media geometrica delle probabilità).
// Il prodotto delle probabilità, usato fino alla 0.3.0, crollava con le parole italiane spezzate in più token e
// con ogni parola in più: i suggerimenti si fermavano quasi sempre alla prima. La media non dipende dalla lunghezza.
// La prima parola deve superare una soglia (se il modello tira a indovinare già lì non si suggerisce niente); dalla
// seconda ci si ferma a una parola molto incerta o quando la media di tutto il seguito scende sotto la soglia della
// lunghezza scelta. Il tetto resta il numero massimo di parole. Solo Foundation.

import Foundation

struct ConfidenceStop {
    /// Perché ci si è fermati, per la diagnostica.
    enum Reason: String, CaseIterable {
        /// Il modello ha finito da solo (fine riga o fine testo).
        case natural
        /// Finiti i token chiesti a metà parola.
        case limit
        /// Prima parola incerta: niente suggerimento.
        case firstWord
        /// Una parola, dalla seconda, molto incerta.
        case weakWord
        /// La media di tutto il seguito è scesa sotto la soglia.
        case average
        /// Raggiunto il numero massimo di parole.
        case maxWords
    }

    let length: SuggestionLength
    let maxWords: Int
    /// Tutto il testo arrivato finora.
    private(set) var text = ""
    /// Il testo fin dove il modello era abbastanza sicuro (a confine di parola); vuoto finché non c'è una parola intera.
    private(set) var confident = ""
    /// Parole intere passate.
    private(set) var words = 0
    /// La prima parola era incerta: niente suggerimento.
    private(set) var rejected = false
    /// Perché ci si è fermati; nil finché il modello scrive.
    private(set) var reason: Reason?
    private var logSum = 0.0
    private var tokens = 0
    private var wordLogSum = 0.0
    private var wordTokens = 0

    init(length: SuggestionLength, maxWords: Int? = nil) {
        self.length = length
        self.maxWords = max(1, maxWords ?? length.maxWords)
    }

    /// La probabilità media per token della prima parola (o del resto della parola in corso). Le soglie vengono dalle
    /// prove con Gemma 3 1B base su frasi italiane: con queste i seguiti buoni arrivano a 9-19 parole, e restano fuori
    /// solo i tiri a indovinare.
    static let firstWordFloor = 0.06

    /// Sotto questa media per token una parola, dalla seconda in poi, è un tiro a indovinare: ci si ferma prima.
    static let wordFloor = 0.03

    /// La probabilità media per token di tutto il seguito: più bassa per i seguiti lunghi.
    var averageFloor: Double {
        switch length {
        case .word: 0.3
        case .short: 0.15
        case .medium: 0.12
        case .long: 0.10
        }
    }

    /// La media geometrica per token: exp della media dei logprob. 1 senza token.
    static func mean(_ logSum: Double, _ tokens: Int) -> Double {
        tokens == 0 ? 1 : exp(logSum / Double(tokens))
    }

    private var wordMean: Double { Self.mean(wordLogSum, wordTokens) }
    private var average: Double { Self.mean(logSum, tokens) }

    /// Aggiunge un pezzo arrivato dal modello con il suo logprob (la somma su `tokenCount` token; nil se il motore non
    /// lo dà). Vero quando conviene fermarsi: il seguito buono è `result`.
    mutating func add(_ piece: String, logprob: Double?, tokenCount: Int = 1) -> Bool {
        let startsWord = piece.first.map { $0.isWhitespace || $0.isNewline } ?? false
        let hasWord = text.contains(where: { !$0.isWhitespace && !$0.isNewline })
        if startsWord, hasWord {
            // Una parola è finita: si tiene se il modello ne era sicuro.
            words += 1
            if words == 1, wordMean < Self.firstWordFloor { rejected = true; reason = .firstWord; return true }
            if words > 1, wordMean < Self.wordFloor { reason = .weakWord; return true }
            if words > 1, average < averageFloor { reason = .average; return true }
            confident = text
            if words >= maxWords { reason = .maxWords; return true }
            wordLogSum = 0
            wordTokens = 0
        }
        text += piece
        if let logprob, tokenCount > 0 {
            // Un token quasi impossibile non deve azzerare tutto: al più -14 (circa un milionesimo) a token.
            let clamped = Swift.max(logprob, -14 * Double(tokenCount))
            wordLogSum += clamped
            logSum += clamped
            wordTokens += tokenCount
            tokens += tokenCount
        }
        return false
    }

    /// Il seguito a risposta finita: `natural` se il modello si è fermato da solo (l'ultima parola è intera).
    /// Vuoto se già la prima parola era incerta.
    mutating func result(natural: Bool) -> String {
        if rejected { return "" }
        if reason == nil { reason = natural ? .natural : .limit }
        if words == 0 {
            // Una parola sola, mai chiusa da uno spazio: vale la soglia della prima.
            if natural, wordMean >= Self.firstWordFloor { return text }
            if natural { reason = .firstWord }
            return ""
        }
        if natural {
            if wordMean >= Self.wordFloor, average >= averageFloor { return text }
            reason = wordMean < Self.wordFloor ? .weakWord : .average
        }
        return confident
    }
}
