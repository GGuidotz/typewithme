// Chrome e le app Electron (Slack, Discord, Notion, VS Code, Obsidian…) costruiscono l'albero Accessibilità del
// contenuto web solo quando un client di assistenza lo chiede: finché nessuno lo fa, il campo in cui scrivi non ha
// cursore né testo leggibili e non compare niente. Era il motivo per cui Type_w/Me funzionava quasi solo in Claude
// Desktop. Quando un'app così passa in primo piano le si chiede l'albero: `AXManualAccessibility` sull'elemento
// applicazione (l'interruttore che Electron documenta per i client di assistenza); a Chrome, che non lo conosce,
// `AXEnhancedUserInterface` (quello di VoiceOver). Il secondo può disturbare i gestori di finestre: solo ai browser
// Chromium, mai alle altre app. Si ripete a ogni passaggio in primo piano: VS Code a volte ignora la prima richiesta.

import AppKit
import ApplicationServices

@MainActor
enum WebAccessibility {
    /// I browser Chromium (prefissi dei bundle id, minuscoli): rifiutano `AXManualAccessibility`.
    private static let chromiumPrefixes = [
        "com.google.chrome", "com.brave.browser", "com.microsoft.edgemac", "company.thebrowser.browser",
        "com.vivaldi.vivaldi", "com.operasoftware.opera", "org.chromium.chromium",
    ]

    /// Le app per cui si è già visto che non serve o non funziona: non si riprova.
    private static var unsupported = Set<pid_t>()
    /// Se un'app è Electron, per bundle id: si guarda nel pacchetto una volta sola.
    private static var electronCache: [String: Bool] = [:]

    /// Da chiamare quando un'app passa in primo piano.
    static func prime(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, pid != getpid(), !unsupported.contains(pid), let bundleID = app.bundleIdentifier else { return }
        let lower = bundleID.lowercased()
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.05)
        if chromiumPrefixes.contains(where: { lower.hasPrefix($0) }) {
            // Chrome risponde con un errore anche quando accetta: conta il valore riletto.
            _ = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            if !isTrue(root, "AXEnhancedUserInterface") {
                unsupported.insert(pid)
                diag(.permissions, "web accessibility: \(bundleID) refused")
            }
            return
        }
        guard isElectron(app) else { return }
        let result = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        switch result {
        case .success:
            break
        case .attributeUnsupported, .actionUnsupported, .notImplemented:
            unsupported.insert(pid)
            diag(.permissions, "web accessibility: \(bundleID) unsupported")
        default:
            break   // l'app si sta ancora avviando o è occupata: si riprova al prossimo passaggio
        }
    }

    /// Un'app Electron ha "Electron Framework.framework" nel pacchetto.
    private static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier, let url = app.bundleURL else { return false }
        if let known = electronCache[bundleID] { return known }
        let framework = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        let result = FileManager.default.fileExists(atPath: framework.path)
        electronCache[bundleID] = result
        return result
    }

    private static func isTrue(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) == true
    }
}
