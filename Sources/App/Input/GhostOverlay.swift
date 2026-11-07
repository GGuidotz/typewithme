// Il testo fantasma: un pannello trasparente, senza ombra, che non prende il fuoco né i clic, appoggiato subito dopo
// il cursore del campo in cui scrivi, con lo stesso carattere quando l'app lo dice e il grigio dei segnaposto. Sempre
// in linea, come testo già scritto: se non ci sta prima del bordo del campo continua sulla riga sotto, dal margine
// sinistro della riga. Se l'app non dice dov'è il cursore non si mostra niente (niente nuvolette sopra il testo).
// Le coordinate dell'AX hanno l'origine in alto a sinistra dello schermo principale; quelle di AppKit in basso.

import AppKit
import SwiftUI

@MainActor
final class GhostOverlay {
    private let panel: PassivePanel
    private let host: NSHostingView<GhostTextView>
    private(set) var isVisible = false
    /// Quante volte non si è potuto mostrare il seguito perché l'app non dice dov'è il cursore (diagnostica).
    private(set) var noCaret = 0

    static let maxLines = 3

    init() {
        panel = PassivePanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        host = NSHostingView(rootView: GhostTextView(lines: [], indent: 0, lineHeight: 16, font: .systemFont(ofSize: 13)))
        panel.contentView = host
    }

    /// Mostra `text` dopo il cursore (`caret`, coordinate AX). `lineStartX`: il margine sinistro della riga, per andare
    /// a capo; nil se non si sa (allora il testo si accorcia alla fine della riga).
    func show(_ text: String, font: NSFont?, caret: CGRect?, fieldFrame: CGRect?, lineStartX: CGFloat? = nil) {
        guard let caret else {
            noCaret += 1
            hide()
            return
        }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let font = font ?? NSFont.systemFont(ofSize: Swift.max(11, Swift.min(caret.height * 0.72, 28)))
        let x = caret.minX + 1
        let probe = CGPoint(x: x, y: screenHeight - caret.maxY + caret.height / 2)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.main
        var right = (screen?.visibleFrame.maxX ?? x + 2000) - 6
        // Il bordo del campo solo se il cursore ci sta dentro: nei campi web il rettangolo del campo a volte è di un
        // altro elemento, e il testo finiva tagliato a zero.
        if let fieldFrame, fieldFrame.width > 40, fieldFrame.maxX - 4 - x > 24 { right = Swift.min(right, fieldFrame.maxX - 4) }
        let lineHeight = Swift.max(caret.height, ceil(font.ascender - font.descender + font.leading))

        var left = x
        var lines: [String]
        if let lineStartX, lineStartX < x, right - lineStartX > 80 {
            left = lineStartX
            lines = Self.wrap(text, font: font, firstWidth: right - x, width: right - lineStartX, maxLines: Self.maxLines)
        } else {
            guard right - x > 24 else { hide(); return }
            lines = [text]   // una riga sola, accorciata alla fine
        }
        // La prima riga vuota (il cursore è al bordo): il seguito parte dalla riga sotto.
        if lines.first?.isEmpty == true, lines.count == 1 { hide(); return }
        let indent = x - left
        let firstWidth = Self.width(lines.first ?? "", font: font) + 6
        let width = lines.count == 1 ? Swift.min(firstWidth, right - x) + indent : right - left
        let height = lineHeight * CGFloat(lines.count)
        host.rootView = GhostTextView(lines: lines, indent: indent, lineHeight: lineHeight, font: font)
        let top = screenHeight - caret.minY - (lineHeight - caret.height) / 2
        panel.setFrame(NSRect(x: left, y: top - height, width: Swift.max(width, 4), height: height), display: true)
        if !isVisible { panel.orderFrontRegardless() }
        isVisible = true
    }

    /// Le righe del seguito: la prima larga `firstWidth` (dal cursore al bordo), le altre `width`. Parole intere;
    /// l'ultima riga si accorcia con i puntini se il testo non ci sta.
    static func wrap(_ text: String, font: NSFont, firstWidth: CGFloat, width: CGFloat, maxLines: Int) -> [String] {
        var lines: [String] = [""]
        var limit = firstWidth
        for word in TextTokens.words(withLeadingSpace: text) {
            let current = lines[lines.count - 1]
            let candidate = current + word
            if Self.width(candidate, font: font) <= limit || (current.isEmpty && lines.count > 1) {
                lines[lines.count - 1] = candidate
                continue
            }
            guard lines.count < maxLines else { break }
            // A capo: la riga nuova comincia senza spazi.
            lines.append(String(word.drop(while: { $0 == " " })))
            limit = width
        }
        return lines
    }

    private static func width(_ text: String, font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    func hide() {
        guard isVisible else { return }
        panel.orderOut(nil)
        isVisible = false
    }
}

/// Un pannello che non diventa mai finestra principale né attiva.
final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct GhostTextView: View {
    var lines: [String]
    var indent: CGFloat
    var lineHeight: CGFloat
    var font: NSFont

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(Font(font as CTFont))
                    .foregroundStyle(Color(nsColor: .placeholderTextColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, index == 0 ? indent : 0)
                    .frame(maxWidth: .infinity, minHeight: lineHeight, maxHeight: lineHeight, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Suggerimento: %@", lines.joined(separator: " ")))
    }
}
