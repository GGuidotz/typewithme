// La voce nella barra dei menu: un'icona piccola disegnata da noi (NSStatusItem, immagine modello: segue chiaro e
// scuro), con tre stati: pronta, in pausa (più chiara), sta pensando (un puntino). Clic: un menu breve con lo stato e
// il motore ("Pronto · Gemma 3 1B", più una riga se Gemma si avvia o scarica il modello), pausa, "in questa app",
// riscrivi, impostazioni, novità, guida, feedback, esci. Le HIG chiedono un menu per le voci semplici, e questa lo
// è: non c'è un pannello.

import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var bag = Set<AnyCancellable>()
    private var drawn: Completer.Status?

    init(model: AppModel) {
        self.model = model
        super.init()
        item.autosaveName = AppInfo.fileName
        item.button?.imagePosition = .imageOnly
        menu.delegate = self
        item.menu = menu
        redraw()
        model.completer.$status.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.redraw() }
            .store(in: &bag)
    }

    private func redraw() {
        let status = model.completer.status
        guard status != drawn else { return }
        drawn = status
        item.button?.image = MenuBarIcon.image(for: status)
        item.button?.toolTip = AppInfo.name + " · " + status.title
        item.button?.setAccessibilityLabel(AppInfo.name + ", " + status.title)
    }

    // MARK: - Menu

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild() }
    }

    private func rebuild() {
        menu.removeAllItems()
        let completer = model.completer, prefs = model.prefs

        let state = NSMenuItem(title: completer.statusLine, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        if let notice = completer.engineNotice {
            let engine = NSMenuItem(title: notice, action: #selector(openEngines), keyEquivalent: "")
            engine.target = self
            menu.addItem(engine)
        }
        if completer.status == .noPermission {
            menu.addItem(withTitle: L("Concedi il permesso…"), action: #selector(openPermissions), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())

        let pause = NSMenuItem(title: prefs.enabled ? L("Metti in pausa") : L("Riprendi"), action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        if let app = completer.frontApp, !app.bundleID.isEmpty, app.bundleID != Bundle.main.bundleIdentifier {
            let excluded = prefs.isExcluded(app.bundleID)
            let perApp = NSMenuItem(title: L("Suggerisci in %@", app.name), action: #selector(toggleApp), keyEquivalent: "")
            perApp.target = self
            perApp.state = excluded ? .off : .on
            perApp.representedObject = app.bundleID
            menu.addItem(perApp)
        }

        let rewrite = NSMenuItem(title: L("Riscrivi la selezione"), action: #selector(rewriteSelection), keyEquivalent: "")
        rewrite.target = self
        rewrite.toolTip = prefs.rewrite.display
        menu.addItem(rewrite)
        let proofread = NSMenuItem(title: L("Correggi il paragrafo"), action: #selector(proofreadParagraph), keyEquivalent: "")
        proofread.target = self
        proofread.toolTip = prefs.proofread.display
        menu.addItem(proofread)
        let synonyms = NSMenuItem(title: L("Sinonimi della selezione"), action: #selector(showSynonyms), keyEquivalent: "")
        synonyms.target = self
        synonyms.toolTip = prefs.synonyms.display
        menu.addItem(synonyms)
        menu.addItem(.separator())

        menu.addItem(withTitle: L("Impostazioni…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: L("Novità e aggiornamenti…"), action: #selector(openUpdates), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Guida iniziale…"), action: #selector(openOnboarding), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Invia un feedback…"), action: #selector(openFeedback), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Esci da Type_w/Me"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func togglePause() { model.completer.setEnabled(!model.prefs.enabled) }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        model.prefs.setExcluded(bundleID, !model.prefs.isExcluded(bundleID))
        model.completer.refreshStatus()
    }

    @objc private func rewriteSelection() {
        // Il menu si chiude e il fuoco torna all'app: un attimo prima di leggere la selezione.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.model.rewrite.trigger() }
    }

    @objc private func proofreadParagraph() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.model.proofreader.trigger() }
    }

    @objc private func showSynonyms() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.model.synonyms.trigger() }
    }

    @objc private func openPermissions() { model.showOnboarding() }
    @objc private func openSettings() { model.showSettings(.general) }
    @objc private func openEngines() { model.showSettings(.engines) }
    @objc private func openUpdates() { model.showSettings(.updates) }
    @objc private func openFeedback() { model.showSettings(.feedback) }
    @objc private func openOnboarding() { model.showOnboarding() }
}

/// L'icona della barra: un cursore di testo con il seguito accennato, come l'icona dell'app. Immagine modello.
enum MenuBarIcon {
    @MainActor
    static func image(for status: Completer.Status) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let dim: CGFloat = {
                switch status {
                case .off, .noPermission, .secureInput, .excluded: 0.45
                default: 1
                }
            }()
            NSColor.black.withAlphaComponent(dim).setFill()
            // Due righe scritte e una terza con il cursore e il seguito tratteggiato.
            let x: CGFloat = 2.5
            NSBezierPath(roundedRect: NSRect(x: x, y: 12.5, width: 11, height: 2), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 8.5, width: 8, height: 2), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 4.5, width: 4.5, height: 2), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: NSRect(x: x + 5.5, y: 3.2, width: 1.4, height: 4.6), xRadius: 0.7, yRadius: 0.7).fill()
            NSColor.black.withAlphaComponent(dim * 0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: x + 8, y: 4.5, width: 2.2, height: 2), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: NSRect(x: x + 11, y: 4.5, width: 2.5, height: 2), xRadius: 1, yRadius: 1).fill()
            if status == .thinking || status == .suggesting {
                NSColor.black.withAlphaComponent(1).setFill()
                NSBezierPath(ovalIn: NSRect(x: 13.5, y: 11.5, width: 3.5, height: 3.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
