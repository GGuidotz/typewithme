// Le sottolineature del correttore: un pannello trasparente che non prende il fuoco né i clic, grande quanto i
// rettangoli degli errori, con una linea tratteggiata sotto ogni parola sbagliata. Rosso per l'ortografia, blu per la
// grammatica; il colore non è l'unico segnale (il pannello delle correzioni dice il tipo con un'icona e una parola).
// Le coordinate dell'AX hanno l'origine in alto a sinistra dello schermo principale; quelle di AppKit in basso.

import AppKit
import SwiftUI

@MainActor
final class UnderlineOverlay {
    struct Mark: Equatable {
        /// Il rettangolo della parola, coordinate AX.
        var rect: CGRect
        var grammar: Bool
    }

    private let panel: PassivePanel
    private let host: NSHostingView<UnderlineView>

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
        host = NSHostingView(rootView: UnderlineView(lines: []))
        panel.contentView = host
    }

    func show(_ marks: [Mark]) {
        guard !marks.isEmpty else { hide(); return }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        // Il rettangolo che le contiene tutte, con un po' di margine sotto per la linea.
        let union = marks.dropFirst().reduce(marks[0].rect) { $0.union($1.rect) }
        let frame = NSRect(x: union.minX - 2, y: screenHeight - union.maxY - 4, width: union.width + 4, height: union.height + 6)
        let lines = marks.map { mark in
            UnderlineView.Line(x: mark.rect.minX - frame.minX, width: mark.rect.width,
                               y: (screenHeight - mark.rect.maxY) - frame.minY, grammar: mark.grammar)
        }
        host.rootView = UnderlineView(lines: lines)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

struct UnderlineView: View {
    struct Line: Hashable {
        var x: CGFloat
        var width: CGFloat
        /// Distanza dal basso del pannello alla base della parola, coordinate AppKit.
        var y: CGFloat
        var grammar: Bool
    }

    var lines: [Line]

    var body: some View {
        Canvas { context, size in
            for line in lines {
                var path = Path()
                let baseline = size.height - line.y + 1   // SwiftUI ha l'origine in alto
                path.move(to: CGPoint(x: line.x, y: baseline))
                path.addLine(to: CGPoint(x: line.x + line.width, y: baseline))
                let color: Color = line.grammar ? .blue : .red
                context.stroke(path, with: .color(color.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 3]))
            }
        }
        .allowsHitTesting(false)
    }
}
