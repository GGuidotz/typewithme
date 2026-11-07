// Quanto essere sicuri prima di suggerire, app per app, imparato da quello che accetti. In un'app dove i suggerimenti
// non li prendi quasi mai se ne mostrano meno e solo quelli di cui il modello è molto sicuro; dove li prendi spesso
// il modello può andare avanti di più. Si contano solo i suggerimenti mostrati e quelli di cui hai preso almeno una
// parola, per app (identificativo del bundle): niente testo. Solo Foundation.

import Foundation

struct AppAdaptation: Codable, Equatable {
    struct Counts: Codable, Equatable {
        var shown = 0
        var accepted = 0
    }

    private(set) var apps: [String: Counts] = [:]

    /// Servono almeno tanti suggerimenti mostrati prima di cambiare qualcosa.
    static let minimumShown = 25
    /// I conteggi si dimezzano oltre questo numero: contano di più le abitudini recenti.
    static let window = 200

    mutating func noteShown(_ bundleID: String) {
        guard !bundleID.isEmpty else { return }
        var c = apps[bundleID, default: Counts()]
        c.shown += 1
        if c.shown > Self.window {
            c.shown /= 2
            c.accepted /= 2
        }
        apps[bundleID] = c
    }

    mutating func noteAccepted(_ bundleID: String) {
        guard !bundleID.isEmpty else { return }
        apps[bundleID, default: Counts()].accepted += 1
    }

    /// Quanto più severe (>1) o più larghe (<1) devono essere le soglie di sicurezza (ConfidenceStop) in questa app.
    func strictness(for bundleID: String) -> Double {
        guard let c = apps[bundleID], c.shown >= Self.minimumShown else { return 1 }
        let rate = Double(c.accepted) / Double(c.shown)
        switch rate {
        case ..<0.08: return 1.6
        case ..<0.18: return 1.3
        case 0.45...: return 0.85
        default: return 1
        }
    }

    /// "com.apple.mail 12/40" per la diagnostica: solo conteggi.
    var summary: String {
        apps.sorted { $0.value.shown > $1.value.shown }.prefix(6)
            .map { "\($0.key) \($0.value.accepted)/\($0.value.shown)" }.joined(separator: ", ")
    }
}
