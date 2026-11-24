// Colori e vetro, in un posto solo. Le forme, i riempimenti e le molle vengono da Sguardo, il sistema di design comune
// (github.com/GGuidotz/sguardo, submodule in Vendor/Sguardo, compilato insieme all'app da build.sh): qui restano i
// colori di Type_w/Me. L'accento predefinito è `SG.Accent.typewithme` (il blu del cursore, Palette.cursor), che chi usa
// l'app può cambiare in Impostazioni › Generale.
// Regola (HIG, Liquid Glass): il vetro solo sui controlli che galleggiano (la barra delle schede); il contenuto usa i
// riempimenti di Sguardo (velo traslucido + filo da 1 pt). Riduci trasparenza e Aumenta contrasto li gestisce il
// sistema. Il testo fantasma usa il grigio dei segnaposto del sistema (GhostOverlay), non un colore nostro.

import AppKit
import SwiftUI

enum Palette {
    /// I colori del marchio, come l'icona: inchiostro, grigio del suggerimento, blu del cursore.
    static let ink = Color(red: 0.15, green: 0.17, blue: 0.21)
    static let ghost = Color(red: 0.69, green: 0.71, blue: 0.75)
    static let cursor = Color(red: 0.18, green: 0.49, blue: 0.96)
    /// Verde dei "tutto bene" (permesso concesso, modello pronto).
    static let calm = Color(red: 0.20, green: 0.70, blue: 0.42)
}

extension View {
    /// Vetro per i controlli che galleggiano. Mai per il contenuto. Il materiale più il velo e il filo di Sguardo
    /// restano il ripiego dove il vetro non c'è.
    func glassSurface(in shape: some InsettableShape, interactive: Bool = false) -> some View {
        sgFloatingChrome(in: shape, interactive: interactive)
    }

    /// Pulsante di vetro (secondario), solo nelle barre che galleggiano. Nel contenuto: `.buttonStyle(.sgSecondary)`.
    @ViewBuilder
    func floatingGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Il pulsante principale di una barra che galleggia: vetro colorato. Nel contenuto: `.buttonStyle(.sgPrimary)`.
    @ViewBuilder
    func floatingGlassProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Una scheda del contenuto, come le righe di Sguardo: velo traslucido (più bianco della finestra in chiaro), filo da
    /// 1 pt, angoli continui da 16 pt. Niente vetro (il vetro è dei controlli), niente ombre, niente animazioni.
    func contentCard(padding: CGFloat = 12, radius: CGFloat = SG.Radius.row) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(ContentCardBackground(radius: radius))
    }
}

private struct ContentCardBackground: ViewModifier {
    var radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .sgRowSurface(in: shape)
            .overlay {
                // Aumenta contrasto: un bordo pieno sopra il filo.
                if contrast == .increased { shape.strokeBorder(Color.primary.opacity(0.35), lineWidth: 1) }
            }
    }
}

extension View {
    /// Un campo di testo nello stile di Sguardo: capsula con il velo dei menu e il filo da 1 pt. Sguardo ha il campo
    /// solo per l'isola (SGIslandField), questo è per le finestre. Su più righe gli angoli sono quelli dei riquadri.
    func sgField(multiline: Bool = false) -> some View {
        modifier(SGFieldStyle(multiline: multiline))
    }
}

private struct SGFieldStyle: ViewModifier {
    var multiline: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: multiline ? SG.Radius.tile : 14, style: .continuous)
        content
            .textFieldStyle(.plain)
            .font(SG.Font.field)
            .padding(.horizontal, 12)
            .padding(.vertical, multiline ? 8 : 0)
            .frame(minHeight: 28)
            .background(shape.fill(SG.Fill.pickerPill))
            .overlay(shape.strokeBorder(SG.Fill.rowBorder, lineWidth: SG.Stroke.hairline))
    }
}

private struct OptionalCard: ViewModifier {
    var framed: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if framed { content.contentCard() } else { content.frame(maxWidth: .infinity, alignment: .leading) }
    }
}

/// Un esempio di come appare un suggerimento: testo scritto, cursore, seguito in grigio. Per la guida e le impostazioni.
/// `framed: false` dentro un gruppo di righe, che ha già la sua superficie.
struct GhostPreview: View {
    var written: String
    var ghost: String
    var accept: String
    var framed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text(written)
                Rectangle().fill(Palette.cursor).frame(width: 2, height: 18).padding(.horizontal, 1)
                Text(ghost).foregroundStyle(Color(nsColor: .placeholderTextColor))
            }
            .font(.system(size: 15))
            .lineLimit(1)
            Text(accept)
                .font(SG.Font.caption)
                .foregroundStyle(SG.Ink.secondary)
        }
        .modifier(OptionalCard(framed: framed))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Esempio: hai scritto %@ e il suggerimento è %@", written, ghost))
    }
}
