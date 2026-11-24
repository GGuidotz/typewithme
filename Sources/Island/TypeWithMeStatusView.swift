// La pagina di Type_w/Me per l'isola di Cocaine: una vista compatta con lo stato, il motore e qualche numero.
// Dipende solo da SwiftUI e da dati semplici (TypeWithMeStatusInfo), non dal Completer né dai colori dell'app, così
// si copia così com'è in un'altra app. I testi arrivano già tradotti (TypeWithMeStatusLabels); i predefiniti sono in
// italiano. Il colore non è mai l'unico segnale: ogni stato ha anche il suo simbolo e la sua frase. Cifre tabellari.
// In Type_w/Me sta in cima a Impostazioni › Generale.

import SwiftUI

/// Quello che la vista mostra: tutto già pronto, niente logica.
struct TypeWithMeStatusInfo: Equatable {
    enum Tone: Equatable {
        /// Pronto; sta pensando o mostra un suggerimento; c'è qualcosa da sistemare; in pausa o escluso.
        case ok, busy, warning, off
    }

    /// Lo stato in parole: "Pronto", "In pausa".
    var statusText: String
    var tone: Tone
    /// Il motore in parole: "Gemma 3 1B", "Apple Intelligence".
    var engineName: String
    /// Una riga in più sul motore ("Gemma: sto scaricando il modello…"), nil se non serve.
    var engineDetail: String?
    var wordsToday: Int
    var wordsTotal: Int
    /// Suggerimenti mostrati e accettati (almeno una parola) in questa sessione.
    var shownThisSession: Int
    var acceptedThisSession: Int
    /// Il tempo medio di risposta del motore, in millisecondi; nil se non ha ancora risposto.
    var averageResponseMs: Int?
}

/// I testi della vista, nella lingua di chi la usa.
struct TypeWithMeStatusLabels {
    var title = "Type_w/Me"
    var engine = "Motore"
    var today = "Parole oggi"
    var total = "Da sempre"
    var session = "Accettati"
    var response = "Risposta"
    /// Il tempo medio con l'unità: "%d ms".
    var milliseconds = "%d ms"
    /// Accettati su mostrati: "%d su %d".
    var acceptedOfShown = "%d su %d"
    var noValue = "–"
}

struct TypeWithMeStatusView: View {
    var info: TypeWithMeStatusInfo
    var labels = TypeWithMeStatusLabels()
    /// Con il suo fondo (come nell'isola). Falso dentro un gruppo di righe, che ha già la sua superficie.
    var framed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 0) {
                metric(labels.today, Self.number(info.wordsToday))
                metric(labels.total, Self.number(info.wordsTotal))
                metric(labels.session, acceptedText)
                metric(labels.response, responseText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if framed { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)) }
        }
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(labels.title).font(.headline)
                    Text(verbatim: "·").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(info.statusText).foregroundStyle(.secondary)
                }
                Text(info.engineDetail ?? info.engineName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(Text(verbatim: "\(labels.engine): \(info.engineDetail ?? info.engineName)"))
            }
            Spacer(minLength: 0)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var acceptedText: String {
        String(format: labels.acceptedOfShown, info.acceptedThisSession, info.shownThisSession)
    }

    private var responseText: String {
        guard let ms = info.averageResponseMs else { return labels.noValue }
        return String(format: labels.milliseconds, ms)
    }

    private static func number(_ value: Int) -> String {
        value.formatted(.number)
    }

    // MARK: - Colori e simboli, solo qui: la vista non usa la palette dell'app.

    private var symbol: String {
        switch info.tone {
        case .ok: "checkmark.circle.fill"
        case .busy: "ellipsis.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .off: "pause.circle.fill"
        }
    }

    private var tint: Color {
        switch info.tone {
        case .ok: Color(red: 0.20, green: 0.70, blue: 0.42)
        case .busy: Color(red: 0.18, green: 0.49, blue: 0.96)
        case .warning: Color.orange
        case .off: Color.secondary
        }
    }
}

// Nomi di prima, per Cocaine finché non passa ai nuovi.
@available(*, deprecated, renamed: "TypeWithMeStatusView")
typealias SuggeritoreStatusView = TypeWithMeStatusView
@available(*, deprecated, renamed: "TypeWithMeStatusInfo")
typealias SuggeritoreStatusInfo = TypeWithMeStatusInfo
@available(*, deprecated, renamed: "TypeWithMeStatusLabels")
typealias SuggeritoreStatusLabels = TypeWithMeStatusLabels
