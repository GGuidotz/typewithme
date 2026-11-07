// Il tap sulla tastiera (CGEventTap): vede ogni tasto prima dell'app che lo riceve, così Tab ed Esc, quando c'è un
// suggerimento, li prendiamo noi e non arrivano all'app. Tutto il resto passa. I tasti che scriviamo noi
// (TextInserter) portano un marchio e vengono ignorati. Un clic del mouse fa sparire il suggerimento.
// Se macOS spegne il tap (è lento a rispondere), lo riaccendiamo. Con l'input sicuro acceso (campi password,
// Terminale con l'eco spento) macOS non consegna i tasti: lo controlliamo prima di suggerire.
//
// Il tap gira su un thread suo, non sul principale: ogni tasto di ogni app aspetta la risposta del tap, e il thread
// principale può essere occupato (testo grigio da disegnare, risposta del modello da pulire, una lettura
// Accessibilità lenta). Sul suo thread il tap decide da solo, con `TapState` (una copia piccola di quello che serve,
// tenuta aggiornata dal Completer), se un tasto è nostro; poi passa il tasto al thread principale, senza aspettare.

import AppKit
import Carbon.HIToolbox
import os

struct KeyStroke {
    let keyCode: UInt16
    let flags: CGEventFlags
    let characters: String
    /// Quando è stato premuto, in secondi dall'avvio del Mac (dal tempo dell'evento, non da quando lo leggiamo).
    let time: TimeInterval

    var hasCommandOrControl: Bool { flags.contains(.maskCommand) || flags.contains(.maskControl) }

    /// Un carattere che finisce nel testo (lettera, cifra, spazio, segno), non un tasto di comando o una freccia.
    var isPrintable: Bool {
        guard let scalar = characters.unicodeScalars.first, !hasCommandOrControl else { return false }
        if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        if (0xF700...0xF8FF).contains(scalar.value) { return false }   // frecce, funzione
        return true
    }

    var isBackspace: Bool { keyCode == 51 }
    var isReturn: Bool { keyCode == 36 || keyCode == 76 }
}

enum KeyDecision { case pass, swallow }

/// Che cosa ha deciso il tap per un tasto che ha preso per sé (o `.none` se l'ha lasciato passare).
enum TapAction { case none, rewrite, acceptWord, acceptAll, dismiss, holdAfterAccept }

/// Quello che il tap deve sapere per decidere sul suo thread. Lo scrive il Completer (thread principale), lo legge e
/// lo aggiorna il tap; sempre sotto lucchetto.
struct TapState: Sendable {
    var enabled = false
    /// Il testo grigio sullo schermo; nil se non ce n'è.
    var suggestion: String?
    var acceptWord = KeyBinding.tab
    var acceptAll = KeyBinding.shiftTab
    var dismiss = KeyBinding.escape
    var rewrite = KeyBinding.controlOptionR
    var lastAcceptAt = Date.distantPast

    /// Le stesse regole di prima, senza toccare l'Accessibilità né il thread principale. Se il suggerimento sparisce o
    /// avanza per questo tasto, lo si segna subito: il tasto dopo trova lo stato giusto anche se il thread principale
    /// non ha ancora finito con questo.
    mutating func decide(_ s: KeyStroke, secureInput: Bool) -> (KeyDecision, TapAction) {
        guard enabled else { return (.pass, .none) }
        if rewrite.matches(keyCode: s.keyCode, flags: s.flags) {
            suggestion = nil
            return (.swallow, .rewrite)
        }
        if secureInput {
            suggestion = nil
            return (.pass, .none)
        }
        if let text = suggestion {
            if acceptWord.matches(keyCode: s.keyCode, flags: s.flags) { return (.swallow, .acceptWord) }
            if acceptAll.matches(keyCode: s.keyCode, flags: s.flags) { return (.swallow, .acceptAll) }
            if dismiss.matches(keyCode: s.keyCode, flags: s.flags) {
                suggestion = nil
                return (.swallow, .dismiss)
            }
            if s.isPrintable, !s.characters.isEmpty, text.hasPrefix(s.characters) {
                let rest = String(text.dropFirst(s.characters.count))
                suggestion = rest.trimmingCharacters(in: .whitespaces).isEmpty ? nil : rest
                return (.pass, .none)
            }
            suggestion = nil
        }
        // Tab subito dopo un'accettazione, mentre arriva il seguito: non va all'app (sposterebbe il fuoco o scriverebbe
        // una tabulazione), il seguito compare tra un attimo.
        if Date().timeIntervalSince(lastAcceptAt) < 0.6,
           acceptWord.matches(keyCode: s.keyCode, flags: s.flags) || acceptAll.matches(keyCode: s.keyCode, flags: s.flags) {
            return (.swallow, .holdAfterAccept)
        }
        return (.pass, .none)
    }
}

@MainActor
final class KeyMonitor {
    /// Il marchio dei tasti che scriviamo noi, nel campo userData degli eventi.
    nonisolated static let ownEventMarker: Int64 = 0x5347_5249

    /// Chiamati sul thread principale, dopo che il tap ha già risposto a macOS.
    var onKeyDown: (@MainActor (KeyStroke, TapAction) -> Void)?
    var onMouseDown: (@MainActor () -> Void)?

    /// Lo stato con cui il tap decide (vedi `TapState`).
    nonisolated let state = OSAllocatedUnfairLock(initialState: TapState())

    /// Scritti solo in start() e stop(), sul thread principale; il tap legge `port` per riaccendersi.
    nonisolated(unsafe) private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    var isRunning: Bool { port != nil }

    /// Vero con l'input sicuro acceso: lì macOS non ci fa vedere i tasti (e noi non dobbiamo suggerire).
    nonisolated static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Crea il tap e il suo thread. Falso se macOS lo rifiuta: manca il permesso Accessibilità (o Monitoraggio input).
    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: keyMonitorCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        let box = TapThreadBox(source: runLoopSource)
        let thread = Thread {
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, box.source, .commonModes)
            box.loop = loop
            box.ready.signal()
            CFRunLoopRun()   // finché stop() non toglie la sorgente e ferma il run loop
        }
        thread.name = "Type_w/Me key tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        box.ready.wait()
        port = tap
        source = runLoopSource
        runLoop = box.loop
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let runLoop, let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        if let runLoop { CFRunLoopStop(runLoop) }
        port = nil
        source = nil
        runLoop = nil
        state.withLock { $0.suggestion = nil }
    }

    /// Sul thread del tap. Risponde a macOS subito; il lavoro vero va al thread principale.
    nonisolated fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return pass
        }
        if type == .leftMouseDown || type == .rightMouseDown {
            state.withLock { $0.suggestion = nil }
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { self.onMouseDown?() }
            }
            return pass
        }
        guard type == .keyDown else { return pass }
        if event.getIntegerValueField(.eventSourceUserData) == Self.ownEventMarker { return pass }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        var length = 0
        var units = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &units)
        let characters = String(utf16CodeUnits: units, count: Swift.min(length, 4))
        let stroke = KeyStroke(keyCode: keyCode, flags: event.flags, characters: characters,
                               time: TimeInterval(event.timestamp) / 1_000_000_000)
        let secure = Self.secureInputActive
        let (decision, action) = state.withLock { $0.decide(stroke, secureInput: secure) }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { self.onKeyDown?(stroke, action) }
        }
        switch decision {
        case .pass: return pass
        case .swallow: return nil
        }
    }
}

/// Passa la sorgente al thread del tap e ne riporta il run loop, una volta sola, prima che start() continui.
private final class TapThreadBox: @unchecked Sendable {
    let source: CFRunLoopSource
    var loop: CFRunLoop?
    let ready = DispatchSemaphore(value: 0)

    init(source: CFRunLoopSource) { self.source = source }
}

/// La funzione C che macOS chiama per ogni evento, sul thread del tap.
private let keyMonitorCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<KeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
