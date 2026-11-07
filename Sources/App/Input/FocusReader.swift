// Legge il campo di testo che ha il fuoco con l'API Accessibilità: chi è (app, ruolo, campo password o no), dov'è il
// cursore, il testo prima e dopo, il rettangolo del cursore (per appoggiarci il testo fantasma), il carattere usato, la
// selezione. Scrive anche: sostituisce la selezione o sposta il cursore, per le app native che lo permettono.
// Le posizioni dell'AX sono in unità UTF-16 (come NSString) e i rettangoli in coordinate schermo con l'origine in alto
// a sinistra dello schermo principale.

import AppKit
import ApplicationServices

struct FocusedField {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    let appName: String
    let role: String
    let isSecure: Bool
    /// Posizione del cursore (o inizio della selezione) e lunghezza della selezione, in unità UTF-16.
    let selection: CFRange
    /// Il rettangolo del campo, coordinate AX (origine in alto a sinistra).
    let frame: CGRect?
    /// Campi WebKit (Mail, Safari, app con WKWebView) che non danno posizioni numeriche ma solo "text marker": il
    /// testo prima e dopo il cursore letto una volta con i marker; la posizione del cursore è la lunghezza di `before`.
    var markerText: (before: String, after: String)? = nil

    var caret: Int { selection.location }
}

enum FocusReader {
    // MARK: - Il campo

    static func focusedField() -> FocusedField? {
        // Prima la domanda a tutto il sistema; se non risponde (succede spesso: errore -25204) o dà un elemento senza
        // cursore, la stessa domanda all'app in primo piano, che di solito risponde subito.
        let system = AXUIElementCreateSystemWide()
        var element = elementValue(system, kAXFocusedUIElementAttribute)
        var selection = element.flatMap { rangeValue($0, kAXSelectedTextRangeAttribute) }
        if selection == nil, let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            let app = AXUIElementCreateApplication(front.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.1)
            if let inApp = elementValue(app, kAXFocusedUIElementAttribute),
               let range = rangeValue(inApp, kAXSelectedTextRangeAttribute) {
                element = inApp
                selection = range
            }
        }
        if selection == nil, let candidate = element ?? frontFocusedElement(), let marked = markerField(candidate) {
            return marked
        }
        guard let element, let selection else { return nil }
        return makeField(element, selection: selection, markerText: nil)
    }

    private static func frontFocusedElement() -> AXUIElement? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.1)
        return elementValue(app, kAXFocusedUIElementAttribute)
    }

    private static func makeField(_ element: AXUIElement, selection: CFRange, markerText: (before: String, after: String)?) -> FocusedField {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        let role = stringValue(element, kAXRoleAttribute) ?? ""
        let subrole = stringValue(element, kAXSubroleAttribute) ?? ""
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        var frame: CGRect?
        if let origin = pointValue(element, kAXPositionAttribute), let size = sizeValue(element, kAXSizeAttribute) {
            frame = CGRect(origin: origin, size: size)
        }
        return FocusedField(element: element, pid: pid, bundleID: app?.bundleIdentifier ?? "", appName: app?.localizedName ?? "",
                            role: role, isSecure: secure, selection: selection, frame: frame, markerText: markerText)
    }

    // MARK: - Campi WebKit (text marker)

    /// Il testo che si legge con i marker, al massimo: oltre si tiene la parte vicina al cursore.
    private static let markerTextLimit = 4000

    /// Un campo modificabile WebKit letto con i text marker: il campo è l'antenato modificabile più alto (il corpo
    /// della mail, non il paragrafo), il testo prima e dopo il cursore si legge dall'inizio e fino alla fine del campo.
    /// nil se l'elemento non ha marker o non è modificabile.
    private static func markerField(_ focused: AXUIElement) -> FocusedField? {
        markerFailure = nil
        func fail(_ step: String) -> FocusedField? { markerFailure = step; return nil }
        guard let selected = copy(focused, "AXSelectedTextMarkerRange") else { return fail("no selection marker") }
        guard let caretStart = startMarker(of: selected, in: focused), let caretEnd = endMarker(of: selected, in: focused)
        else { return fail("no caret marker") }
        // Il campo: l'antenato modificabile più alto dell'elemento con il fuoco o di quello sotto il cursore. In Mail il
        // fuoco sta sull'area web, che è tutta modificabile (il documento intero è la mail): allora il campo è lei.
        var field = editableRoot(focused)
        if field == nil, let atCaret = parameterized(focused, "AXUIElementForTextMarker", caretStart),
           CFGetTypeID(atCaret) == AXUIElementGetTypeID() {
            field = editableRoot(atCaret as! AXUIElement)
        }
        // Solo in Mail: in una pagina web qualunque l'area web ha un cursore anche quando non si può scrivere.
        if field == nil, stringValue(focused, kAXRoleAttribute) == "AXWebArea", isMail(focused) { field = focused }
        guard let field else { return fail("no editable element") }
        // Inizio e fine del campo: dal suo intervallo, o dagli attributi di inizio e fine documento dell'area web.
        var fieldStart: CFTypeRef?
        var fieldEnd: CFTypeRef?
        if let whole = parameterized(field, "AXTextMarkerRangeForUIElement", field) {
            fieldStart = startMarker(of: whole, in: field)
            fieldEnd = endMarker(of: whole, in: field)
        }
        if fieldStart == nil { fieldStart = copy(field, "AXStartTextMarker") }
        if fieldEnd == nil { fieldEnd = copy(field, "AXEndTextMarker") }
        guard let fieldStart, let fieldEnd else { return fail("no field range") }
        guard let before = markerString(field, from: fieldStart, to: caretStart) else { return fail("no text before") }
        let after = markerString(field, from: caretEnd, to: fieldEnd) ?? ""
        let selectedText = markerString(field, from: caretStart, to: caretEnd) ?? ""
        let caret = before.utf16.count
        let selection = CFRange(location: caret, length: selectedText.utf16.count)
        let keptBefore = String(before.suffix(markerTextLimit))
        let keptAfter = String(after.prefix(markerTextLimit))
        return makeField(field, selection: selection, markerText: (keptBefore, keptAfter))
    }

    /// Il passo in cui l'ultima lettura con i marker si è fermata (per la diagnostica), nil se è andata.
    nonisolated(unsafe) private(set) static var markerFailure: String?

    private static func isMail(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        return id == "com.apple.mail" || id.hasPrefix("com.apple.MailCompositionService")
            || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.mail"
    }

    private static func editableRoot(_ element: AXUIElement) -> AXUIElement? {
        elementValue(element, "AXHighestEditableAncestor") ?? elementValue(element, "AXEditableAncestor")
            ?? (isEditable(element) ? element : nil)
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        if let role = stringValue(element, kAXRoleAttribute), role == kAXTextAreaRole || role == kAXTextFieldRole { return true }
        return (copy(element, "AXEditable") as? NSNumber)?.boolValue == true
    }

    /// L'inizio e la fine di un intervallo di marker: con le funzioni pubbliche di macOS (i marker sono tipi CF dal
    /// macOS 12; WebKit recente non risponde più agli attributi "AXStart/EndTextMarkerForTextMarkerRange"), poi con
    /// gli attributi per le versioni vecchie.
    private static func startMarker(of range: CFTypeRef, in element: AXUIElement) -> CFTypeRef? {
        if CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() {
            return AXTextMarkerRangeCopyStartMarker(range as! AXTextMarkerRange)
        }
        return parameterized(element, "AXStartTextMarkerForTextMarkerRange", range)
    }

    private static func endMarker(of range: CFTypeRef, in element: AXUIElement) -> CFTypeRef? {
        if CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() {
            return AXTextMarkerRangeCopyEndMarker(range as! AXTextMarkerRange)
        }
        return parameterized(element, "AXEndTextMarkerForTextMarkerRange", range)
    }

    private static func markerString(_ element: AXUIElement, from start: CFTypeRef, to end: CFTypeRef) -> String? {
        var range = parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray)
        if range == nil, CFGetTypeID(start) == AXTextMarkerGetTypeID(), CFGetTypeID(end) == AXTextMarkerGetTypeID() {
            range = AXTextMarkerRangeCreate(kCFAllocatorDefault, start as! AXTextMarker, end as! AXTextMarker)
        }
        guard let range else { return nil }
        return parameterized(element, "AXStringForTextMarkerRange", range) as? String
    }

    private static func parameterized(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &out) == .success else { return nil }
        return out
    }

    /// Che cosa espone l'elemento con il fuoco quando il campo non si trova, per la diagnostica: ruolo e attributi
    /// presenti, mai testo. "none" se nessun elemento ha il fuoco.
    static func focusDescription() -> String {
        let system = AXUIElementCreateSystemWide()
        guard let element = elementValue(system, kAXFocusedUIElementAttribute) ?? frontFocusedElement() else { return "none" }
        let role = stringValue(element, kAXRoleAttribute) ?? "?"
        var parts = [role]
        if copy(element, kAXSelectedTextRangeAttribute) != nil { parts.append("range") }
        if copy(element, "AXSelectedTextMarkerRange") != nil { parts.append("marker") }
        if elementValue(element, "AXHighestEditableAncestor") != nil { parts.append("editable ancestor") }
        if isEditable(element) { parts.append("editable") }
        if let failure = markerFailure { parts.append(failure) }
        return parts.joined(separator: ", ")
    }

    /// L'app in primo piano, per il menu e le esclusioni.
    static func frontmostApp() -> (bundleID: String, name: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return (app.bundleIdentifier ?? "", app.localizedName ?? "")
    }

    // MARK: - Testo

    /// Gli ultimi `max` caratteri prima del cursore.
    static func text(before field: FocusedField, max: Int) -> String? {
        if let marked = field.markerText { return String(marked.before.suffix(max)) }
        let caret = field.caret
        let start = Swift.max(0, caret - max)
        let range = CFRange(location: start, length: caret - start)
        if range.length == 0 { return "" }
        if let s = string(forRange: range, in: field.element) { return s }
        guard let value = stringValue(field.element, kAXValueAttribute) else { return nil }
        let units = Array(value.utf16)
        guard caret <= units.count else { return nil }
        return String(utf16CodeUnits: Array(units[start..<caret]), count: caret - start)
    }

    /// Il testo dopo il cursore, fino a `max` caratteri e fino a fine riga (o tutto, con `wholeLines`).
    static func text(after field: FocusedField, max: Int, wholeLines: Bool = false) -> String? {
        let end = field.selection.location + field.selection.length
        var raw: String?
        if let marked = field.markerText {
            let piece = String(marked.after.prefix(max))
            return wholeLines ? piece : (piece.components(separatedBy: .newlines).first ?? piece)
        }
        if let total = intValue(field.element, kAXNumberOfCharactersAttribute) {
            let length = Swift.min(max, total - end)
            if length <= 0 { return "" }
            raw = string(forRange: CFRange(location: end, length: length), in: field.element)
        }
        if raw == nil, let value = stringValue(field.element, kAXValueAttribute) {
            let units = Array(value.utf16)
            guard end <= units.count else { return nil }
            let stop = Swift.min(units.count, end + max)
            raw = String(utf16CodeUnits: Array(units[end..<stop]), count: stop - end)
        }
        guard let raw else { return nil }
        if wholeLines { return raw }
        return raw.components(separatedBy: .newlines).first ?? raw
    }

    static func selectedText(_ field: FocusedField) -> String? {
        guard field.selection.length > 0 else { return nil }
        if let s = stringValue(field.element, kAXSelectedTextAttribute), !s.isEmpty { return s }
        return string(forRange: field.selection, in: field.element)
    }

    // MARK: - Dove

    /// Il rettangolo del cursore (larghezza zero, altezza della riga), coordinate AX. nil se l'app non lo dice.
    static func caretBounds(_ field: FocusedField, afterNewline: Bool) -> CGRect? {
        caretInfo(field, afterNewline: afterNewline).rect
    }

    /// Il rettangolo del cursore e da dove viene (per la diagnostica: "range", "marker", "outside", "none").
    /// Chrome e Safari a volte danno rettangoli plausibili ma sbagliati (all'origine dello schermo, o di un altro
    /// elemento): si tiene solo un rettangolo dentro il campo, se il campo dice dov'è.
    static func caretInfo(_ field: FocusedField, afterNewline: Bool) -> (rect: CGRect?, source: String) {
        let caret = field.caret
        let area = field.frame.flatMap { $0.width > 4 && $0.height > 4 ? $0.insetBy(dx: -24, dy: -24) : nil }
        var outside = false
        func plausible(_ r: CGRect) -> Bool {
            guard r.height > 4, r.height < 300, r.width >= 0, r != .zero, !(r.minX == 0 && r.minY == 0) else { return false }
            if let area, !area.contains(CGPoint(x: r.minX, y: r.midY)), !area.contains(CGPoint(x: r.maxX, y: r.midY)) {
                outside = true
                return false
            }
            return true
        }
        if !afterNewline, caret > 0, let r = bounds(forRange: CFRange(location: caret - 1, length: 1), in: field.element), plausible(r) {
            return (CGRect(x: r.maxX, y: r.minY, width: 0, height: r.height), "range")
        }
        if let r = bounds(forRange: CFRange(location: caret, length: 1), in: field.element), plausible(r) {
            return (CGRect(x: r.minX, y: r.minY, width: 0, height: r.height), "range")
        }
        if let r = bounds(forRange: CFRange(location: caret, length: 0), in: field.element), plausible(r) {
            return (CGRect(x: r.minX, y: r.minY, width: 0, height: r.height), "range")
        }
        // Chrome, Electron e WebKit spesso non danno i rettangoli per posizione ma sì per "text marker".
        if let marker = copy(field.element, "AXSelectedTextMarkerRange") {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(field.element, "AXBoundsForTextMarkerRange" as CFString, marker, &out) == .success,
               let v = out, CFGetTypeID(v) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue((v as! AXValue), .cgRect, &rect), plausible(rect) {
                    return (CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height), "marker")
                }
            }
        }
        return (nil, outside ? "outside" : "none")
    }

    /// La x del margine sinistro della riga del cursore (il primo carattere del paragrafo), coordinate AX: serve a
    /// continuare il testo fantasma sulla riga sotto. `before` è il testo che finisce al cursore. nil se non si sa.
    static func lineStartX(_ field: FocusedField, before: String) -> CGFloat? {
        let afterNewline: Int
        if let newline = before.lastIndex(where: { $0.isNewline }) {
            afterNewline = before[before.index(after: newline)...].utf16.count
        } else if before.utf16.count < field.caret {
            return nil   // il testo letto non arriva all'inizio del campo
        } else {
            afterNewline = before.utf16.count
        }
        let start = field.caret - afterNewline
        guard start >= 0, start < field.caret,
              let r = bounds(forRange: CFRange(location: start, length: 1), in: field.element), r.height > 4 else { return nil }
        return r.minX
    }

    /// Il rettangolo della selezione (per il pannello "Riscrivi"), coordinate AX.
    static func selectionBounds(_ field: FocusedField) -> CGRect? {
        guard field.selection.length > 0 else { return caretBounds(field, afterNewline: false) }
        return bounds(forRange: field.selection, in: field.element)
    }

    /// Il carattere del testo prima del cursore, se l'app lo espone (AppKit sì, molte altre no).
    static func font(_ field: FocusedField) -> NSFont? {
        let caret = field.caret
        guard caret > 0 else { return nil }
        var range = CFRange(location: caret - 1, length: 1)
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field.element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
                                                         param, &out) == .success,
              let attributed = out as? NSAttributedString, attributed.length > 0 else { return nil }
        let attributes = attributed.attributes(at: 0, effectiveRange: nil)
        if let font = attributes[.font] as? NSFont { return font }
        if let info = attributes[NSAttributedString.Key("AXFont")] as? [String: Any] {
            let size = (info["AXFontSize"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 13
            if let name = info["AXFontName"] as? String, let font = NSFont(name: name, size: size) { return font }
            return NSFont.systemFont(ofSize: size)
        }
        return nil
    }

    // MARK: - Scrivere

    /// Sostituisce la selezione con `text` (per le app che accettano la scrittura via AX). Vero se è andata.
    @discardableResult
    static func replaceSelection(_ field: FocusedField, with text: String) -> Bool {
        AXUIElementSetAttributeValue(field.element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    @discardableResult
    static func select(_ field: FocusedField, range: CFRange) -> Bool {
        var r = range
        guard let value = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(field.element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    /// Sostituisce `length` unità prima della posizione `end` con `replacement`, via AX; il cursore finisce dopo il
    /// testo nuovo più `keepAfter` unità (lo spazio o il segno appena scritto). Vero se è andata.
    static func replace(_ field: FocusedField, length: Int, endingAt end: Int, with replacement: String, keepAfter: Int) -> Bool {
        let start = end - length
        guard start >= 0, select(field, range: CFRange(location: start, length: length)) else { return false }
        guard replaceSelection(field, with: replacement) else {
            // Rimettiamo il cursore dov'era.
            select(field, range: CFRange(location: end + keepAfter, length: 0))
            return false
        }
        select(field, range: CFRange(location: start + replacement.utf16.count + keepAfter, length: 0))
        return true
    }

    // MARK: - Letture di base

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func elementValue(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = copy(element, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    private static func intValue(_ element: AXUIElement, _ attribute: String) -> Int? {
        (copy(element, attribute) as? NSNumber)?.intValue
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let v = copy(element, attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    private static func rangeValue(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        guard let v = axValue(element, attribute) else { return nil }
        var range = CFRange()
        return AXValueGetValue(v, .cfRange, &range) ? range : nil
    }

    private static func pointValue(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let v = axValue(element, attribute) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &point) ? point : nil
    }

    private static func sizeValue(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let v = axValue(element, attribute) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(v, .cgSize, &size) ? size : nil
    }

    private static func string(forRange range: CFRange, in element: AXUIElement) -> String? {
        var r = range
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, param, &out) == .success
        else { return nil }
        return out as? String
    }

    private static func bounds(forRange range: CFRange, in element: AXUIElement) -> CGRect? {
        var r = range
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &out) == .success,
              let v = out, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue((v as! AXValue), .cgRect, &rect) ? rect : nil
    }
}
