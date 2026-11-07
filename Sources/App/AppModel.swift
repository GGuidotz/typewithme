// Type_w/Me: il seguito di quello che scrivi, in ogni app del Mac. Vive nella barra dei menu (LSUIElement: niente
// Dock). AppModel tiene insieme preferenze, il completatore (tasti, campo, modello, testo fantasma), la riscrittura,
// gli aggiornamenti e le finestre. Il ciclo di vita è AppKit (Sources/App/Main.swift).

import AppKit
import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let prefs: Preferences
    let completer: Completer
    let rewrite: RewriteController
    let proofreader: Proofreader
    let synonyms: SynonymsController
    let updater: Updater
    @Published var settingsTab: SettingsTab = .general

    private let settingsWindow = SettingsWindowController()
    private let onboardingWindow = OnboardingWindowController()
    private let whatsNewWindow = WhatsNewWindowController()

    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    private init() {
        let prefs = Preferences()
        self.prefs = prefs
        let completer = Completer(prefs: prefs)
        self.completer = completer
        rewrite = RewriteController(prefs: prefs, completer: completer)
        updater = Updater(prefs: prefs)
        proofreader = Proofreader(prefs: prefs)
        synonyms = SynonymsController(completer: completer)
        completer.onRewriteRequested = { [weak self] in self?.rewrite.trigger() }
        completer.onProofreadRequested = { [weak self] in self?.proofreader.trigger() }
        completer.onSynonymsRequested = { [weak self] in self?.synonyms.trigger() }
        completer.onTextChanged = { [weak self] in self?.proofreader.textChanged() }
        completer.onContextLost = { [weak self] in self?.proofreader.reset() }
        // Con del testo selezionato la scorciatoia del correttore corregge la selezione in Riscrivi.
        proofreader.onProofreadSelection = { [weak self] in
            guard let self else { return }
            self.rewrite.trigger()
            self.rewrite.run(.fix)
        }
    }

    func didLaunch() {
        diag(.app, "launched \(appVersion), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        completer.start()
        proofreader.prewarm()
        updater.start()
    }

    func showSettings(_ tab: SettingsTab?) {
        if let tab { settingsTab = tab }
        settingsWindow.show(model: self)
    }

    /// La guida dei primi passi: da sola al primo avvio, poi da Impostazioni › Generale e dal menu.
    func showOnboarding() {
        onboardingWindow.show(model: self)
    }

    /// Le novità: da sole dopo un aggiornamento, oppure da Impostazioni › Aggiornamenti.
    func showWhatsNewIfUpdated(firstLaunch: Bool) {
        whatsNewWindow.showIfUpdated(firstLaunch: firstLaunch)
    }

    func showWhatsNew() {
        whatsNewWindow.showCurrent()
    }
}
