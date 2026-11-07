// Il contesto dall'app in cui scrivi, letto con Accessibilità (il permesso c'è già): il titolo della finestra e il
// testo che mostra (la mail a cui rispondi, la chat, la pagina), senza il campo in cui scrivi. Più preciso e molto più
// leggero dell'OCR dello schermo, e non serve Registrazione schermo. Come ScreenContext non aspetta mai: `context(for:)`
// risponde con l'ultima lettura della stessa finestra e intanto, se è vecchia, ne avvia una in background.
// Privacy: solo in memoria, mai su disco, mai nel registro (solo conteggi).

import AppKit
import ApplicationServices

@MainActor
final class WindowText {
    struct Snapshot {
        let title: String?
        let text: String
    }

    private static let maxAge: TimeInterval = 8
    private nonisolated static let maxCharacters = 1_500
    private nonisolated static let maxNodes = 800
    private nonisolated static let budget: TimeInterval = 0.06

    private var cached: (window: Int, snapshot: Snapshot, date: Date)?
    private var running = false
    /// Letture riuscite, per la diagnostica.
    private(set) var reads = 0
    private(set) var lastCharacters = 0

    /// Un elemento di Accessibilità da passare a un altro thread: le chiamate AX si possono fare da qualunque thread.
    private struct Box: @unchecked Sendable { let element: AXUIElement }

    /// Subito: l'ultima lettura della finestra del campo, se è la stessa. Se manca o è vecchia ne avvia una.
    func context(for field: FocusedField) -> Snapshot? {
        guard let window = Self.window(of: field.element) else { return nil }
        let key = Int(CFHash(window))
        var result: Snapshot?
        var fresh = false
        if let c = cached, c.window == key {
            result = c.snapshot
            fresh = Date().timeIntervalSince(c.date) < Self.maxAge
        }
        if !fresh, !running {
            running = true
            let boxWindow = Box(element: window)
            let boxField = Box(element: field.element)
            Task.detached(priority: .utility) { [weak self] in
                let snapshot = Self.read(window: boxWindow.element, skipping: boxField.element)
                await self?.store(snapshot, window: key)
            }
        }
        return result
    }

    private func store(_ snapshot: Snapshot, window key: Int) {
        running = false
        cached = (key, snapshot, Date())
        reads += 1
        lastCharacters = snapshot.text.count
    }

    func invalidate() { cached = nil }

    // MARK: - Lettura (fuori dal main actor)

    private static func window(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// Il titolo e il testo visibile della finestra, in ordine di lettura, senza il campo `skipping`, i campi password
    /// e i pezzi ripetuti. Si ferma a `maxNodes` elementi o dopo `budget` secondi: meglio poco che lento.
    private nonisolated static func read(window: AXUIElement, skipping field: AXUIElement) -> Snapshot {
        AXUIElementSetMessagingTimeout(window, 0.05)
        let title = string(window, kAXTitleAttribute)
        let deadline = Date().addingTimeInterval(budget)
        var queue: [AXUIElement] = [window]
        var index = 0
        var seen = Set<String>()
        var pieces: [String] = []
        var total = 0
        while index < queue.count, index < maxNodes, total < maxCharacters, Date() < deadline {
            let element = queue[index]
            index += 1
            if CFEqual(element, field) { continue }
            let role = string(element, kAXRoleAttribute) ?? ""
            let subrole = string(element, kAXSubroleAttribute) ?? ""
            if role == "AXSecureTextField" || subrole == "AXSecureTextField" { continue }
            switch role {
            case "AXStaticText", "AXTextArea", "AXTextField", "AXHeading":
                if let text = string(element, kAXValueAttribute) ?? string(element, kAXTitleAttribute) {
                    let clean = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    if clean.count >= 2, !seen.contains(clean) {
                        seen.insert(clean)
                        let piece = String(clean.prefix(600))
                        pieces.append(piece)
                        total += piece.count + 1
                    }
                }
                // Il testo di un campo è già tutto nel suo valore: i figli lo ripeterebbero.
                if role != "AXHeading" { continue }
            case "AXImage", "AXScrollBar", "AXMenuBar", "AXMenu", "AXToolbar":
                continue
            default:
                break
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list)
            }
        }
        var text = pieces.joined(separator: "\n")
        if text.count > maxCharacters { text = String(text.prefix(maxCharacters)) }
        return Snapshot(title: title.flatMap { $0.isEmpty ? nil : $0 }, text: text)
    }

    private nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
