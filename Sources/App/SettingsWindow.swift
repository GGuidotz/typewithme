// La finestra delle impostazioni: una finestra AppKit con dentro SwiftUI, perché senza il ciclo di vita di SwiftUI
// la scena Settings non c'è. Barra del titolo trasparente: la barra delle schede (Sguardo) galleggia in fondo, sopra il contenuto.
// Il fondo è un materiale traslucido (quello delle barre laterali), disegnato dal sistema. Come in What's Going On.

import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, suggestions, apps, personalization, engines, updates, feedback
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L("Generale")
        case .suggestions: L("Suggerimenti")
        case .apps: L("App")
        case .personalization: L("Personalizzazione")
        case .engines: L("Motori")
        case .updates: L("Aggiornamenti")
        case .feedback: L("Feedback")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .suggestions: "text.cursor"
        case .apps: "macwindow.on.rectangle"
        case .personalization: "person.text.rectangle"
        case .engines: "cpu"
        case .updates: "arrow.down.circle"
        case .feedback: "bubble.left.and.text.bubble.right"
        }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let w = TranslucentWindow.make(SettingsView(model: model), size: SettingsView.size)
            w.delegate = self
            window = w
        }
        window?.title = L("Impostazioni di Type_w/Me")   // per Mission Control e VoiceOver, anche dopo un cambio di lingua
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Finestra chiusa: via anche le sue viste.
    nonisolated func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.window?.contentViewController = nil
                self?.window = nil
            }
        }
    }
}

/// Una finestra con il fondo traslucido del sistema (materiale delle barre laterali) e la barra del titolo trasparente.
@MainActor
enum TranslucentWindow {
    static func make(_ root: some View, size: CGSize, resizable: Bool = false) -> NSWindow {
        let host = NSHostingController(rootView: root)
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        let container = NSViewController()
        container.view = effect
        container.addChild(host)
        effect.frame = NSRect(origin: .zero, size: size)
        host.view.frame = effect.bounds
        host.view.autoresizingMask = [.width, .height]
        effect.addSubview(host.view)
        let w = NSWindow(contentViewController: container)
        w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { w.styleMask.insert(.resizable) }
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.setContentSize(size)
        w.center()
        return w
    }
}

/// La barra delle schede (Sguardo): una capsula che galleggia sopra il fondo della finestra, di vetro su macOS 26. La
/// scheda scelta mostra il nome, le altre solo il simbolo (il nome resta nel suggerimento e per VoiceOver). ⌘1…⌘7.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        SGFloatingTabBar(SettingsTab.allCases.map { SGTab($0, title: $0.title, systemImage: $0.symbol) },
                         selection: $selection, commandShortcuts: true)
    }
}
