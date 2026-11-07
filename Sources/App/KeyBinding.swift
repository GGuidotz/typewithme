// Una combinazione di tasti (codice del tasto + modificatori), salvata nelle preferenze e confrontata con quello che
// arriva dal tap della tastiera. Con il nome da mostrare ("⇧⇥", "⌃⌥R") e un controllo per registrarne una nuova.

import AppKit
import SwiftUI

struct KeyBinding: Codable, Equatable {
    var keyCode: UInt16
    /// Solo ⌘ ⇧ ⌥ ⌃, come CGEventFlags.
    var modifiers: UInt64

    static let relevantFlags: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    static let tab = KeyBinding(keyCode: 48, modifiers: 0)
    static let shiftTab = KeyBinding(keyCode: 48, modifiers: CGEventFlags.maskShift.rawValue)
    static let escape = KeyBinding(keyCode: 53, modifiers: 0)
    static let controlOptionR = KeyBinding(keyCode: 15, modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue)
    static let controlOptionG = KeyBinding(keyCode: 5, modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue)
    static let controlOptionS = KeyBinding(keyCode: 1, modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue)

    init(keyCode: UInt16, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(keyCode: UInt16, flags: CGEventFlags) {
        self.keyCode = keyCode
        self.modifiers = flags.intersection(Self.relevantFlags).rawValue
    }

    init(event: NSEvent) {
        keyCode = event.keyCode
        var flags: CGEventFlags = []
        if event.modifierFlags.contains(.command) { flags.insert(.maskCommand) }
        if event.modifierFlags.contains(.shift) { flags.insert(.maskShift) }
        if event.modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
        if event.modifierFlags.contains(.control) { flags.insert(.maskControl) }
        modifiers = flags.rawValue
    }

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    func matches(keyCode code: UInt16, flags eventFlags: CGEventFlags) -> Bool {
        code == keyCode && eventFlags.intersection(Self.relevantFlags) == flags
    }

    /// "⌃⌥R", "⇧⇥", "⎋".
    var display: String {
        var out = ""
        if flags.contains(.maskControl) { out += "⌃" }
        if flags.contains(.maskAlternate) { out += "⌥" }
        if flags.contains(.maskShift) { out += "⇧" }
        if flags.contains(.maskCommand) { out += "⌘" }
        return out + Self.keyName(keyCode)
    }

    /// Il nome del tasto: simbolo per i tasti speciali, lettera o cifra per quelli della tastiera americana.
    static func keyName(_ code: UInt16) -> String {
        if let special = specialKeys[code] { return special }
        if let letter = ansiKeys[code] { return letter }
        return "#\(code)"
    }

    private static let specialKeys: [UInt16: String] = [
        48: "⇥", 53: "⎋", 36: "↩", 76: "⌤", 49: "␣", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static let ansiKeys: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
    ]
}

/// Mostra una combinazione e permette di registrarne un'altra: clic su "Cambia", poi il tasto. Esc annulla.
struct KeyBindingRecorder: View {
    var title: String
    @Binding var binding: KeyBinding
    var reset: KeyBinding
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(recording ? L("Premi i tasti…") : binding.display)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .frame(minWidth: 70)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(recording ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07)))
                    .accessibilityLabel(L("Combinazione attuale: %@", binding.display))
                Button(recording ? L("Annulla") : L("Cambia")) { recording ? stop() : start() }
                if binding != reset, !recording {
                    Button(L("Ripristina")) { binding = reset }
                }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc da solo annulla; i modificatori da soli non arrivano qui (sono flagsChanged).
            if event.keyCode == 53, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
                stop()
                return nil
            }
            binding = KeyBinding(event: event)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
