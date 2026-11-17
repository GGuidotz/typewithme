// Cifratura della memoria delle frasi (Sources/Core/PhraseMemory.swift, che usa solo Foundation): AES-GCM con la stessa
// chiave della cronologia di scrittura, nel Portachiavi (solo su questo Mac). Senza chiave restituisce nil e la
// memoria resta in RAM.

import CryptoKit
import Foundation

enum PhraseSealing {
    /// Cifra; la chiave si crea se manca. nil se il Portachiavi non la dà.
    @Sendable static func seal(_ plain: Data) -> Data? {
        guard let key = TypingHistory.key(create: true) else { return nil }
        return try? AES.GCM.seal(plain, using: key).combined
    }

    /// Decifra; nil se manca la chiave o il file non è valido.
    @Sendable static func open(_ sealed: Data) -> Data? {
        guard let key = TypingHistory.key(create: false),
              let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}
