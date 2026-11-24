// La schermata delle novità: si apre da sola al primo avvio dopo un aggiornamento (non dopo la prima installazione, lì
// c'è la guida) e si riapre da Impostazioni › Aggiornamenti. Breve e da leggere in un colpo d'occhio: il riassunto della
// versione, poi New features, Improvements e Bug fixes, ogni voce con il suo titolo in evidenza e una riga sotto.
// Il testo viene dal CHANGELOG.md incluso nell'app (Sources/App/Changelog.swift).

import AppKit
import SwiftUI

@MainActor
final class WhatsNewWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private static let seenKey = "whatsNewSeenVersion"

    /// All'avvio: se l'app è stata aggiornata da quando l'hai aperta l'ultima volta, le novità di quelle versioni.
    /// Alla prima installazione segna solo la versione: le novità di un'app appena presa non servono.
    func showIfUpdated(firstLaunch: Bool) {
        let current = Self.currentVersion
        let defaults = UserDefaults.standard
        let seen = defaults.string(forKey: Self.seenKey)
        defaults.set(current, forKey: Self.seenKey)
        if firstLaunch { return }
        // Chi aggiorna da una versione senza questa schermata non ha la chiave: vede la versione nuova.
        let after = seen ?? Self.previous(of: current)
        guard Version(current) > Version(after) else { return }
        let entries = Changelog.entries(after: after, upTo: current, in: Changelog.load())
        guard !entries.isEmpty else { return }
        diag(.app, "what's new shown for \(entries.map(\.version).joined(separator: ", "))")
        show(entries)
    }

    /// Da Impostazioni: le novità della versione installata.
    func showCurrent() {
        guard let entry = Changelog.load().first(where: { $0.version == Self.currentVersion }) ?? Changelog.load().first
        else { return }
        show([entry])
    }

    private func show(_ entries: [ChangelogEntry]) {
        window?.close()
        let view = WhatsNewView(entries: entries) { [weak self] in self?.window?.performClose(nil) }
        let w = TranslucentWindow.make(view, size: WhatsNewView.size)
        w.delegate = self
        w.title = L("Novità di Type_w/Me")
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.window?.contentViewController = nil
                self?.window = nil
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// "0.6.0" → "0.5.99": tutto ciò che viene prima della versione installata.
    private static func previous(of version: String) -> String {
        var parts = version.split(separator: ".").map { Int($0) ?? 0 }
        guard let last = parts.indices.last else { return "0" }
        if parts[last] > 0 {
            parts[last] -= 1
        } else if last > 0 {
            parts[last - 1] = max(0, parts[last - 1] - 1)
            parts[last] = 99
        }
        return parts.map(String.init).joined(separator: ".")
    }
}

struct WhatsNewView: View {
    static let size = CGSize(width: 560, height: 640)

    let entries: [ChangelogEntry]
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 32)
                .padding(.top, 40)
                .padding(.bottom, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(entries) { entry in
                        if entries.count > 1 {
                            Text(L("Versione %@", entry.version))
                                .font(SG.Font.instruction)
                        }
                        ForEach(entry.sections) { section in
                            SectionBlock(section: section)
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text(L("Le note complete sono in Impostazioni › Aggiornamenti."))
                    .font(SG.Font.caption)
                    .foregroundStyle(SG.Ink.secondary)
                Spacer()
                Button(L("Continua"), action: close)
                    .buttonStyle(SGCapsuleButtonStyle(.primary, size: .large))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .sguardoAccent(default: .typewithme)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Novità"))
                    .font(SG.Font.bodyEmphasis)
                    .foregroundStyle(SG.Ink.secondary)
                Text(verbatim: "\(AppInfo.name) \(entries.first?.version ?? "")")
                    .font(SG.Font.title)
                if let summary = entries.first?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(SG.Font.instruction)
                        .foregroundStyle(SG.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Un gruppo (New features, Improvements, Bug fixes): intestazione con simbolo e conteggio, poi le voci.
private struct SectionBlock: View {
    let section: ChangelogSection
    @Environment(\.sgAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(Self.executiveTitle(section.title))
                    .font(SG.Font.bodyEmphasis)
                Text("\(section.items.count)")
                    .font(SG.Font.label)
                    .monospacedDigit()
                    .foregroundStyle(SG.Ink.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(SG.Fill.neutralButton, in: Capsule())
                    .accessibilityLabel(L("%d voci", section.items.count))
            }
            ForEach(section.items, id: \.self) { item in
                let parts = Self.split(item)
                VStack(alignment: .leading, spacing: 2) {
                    if let title = parts.title {
                        Text(title).font(SG.Font.bodyEmphasis).foregroundStyle(SG.Ink.primary)
                    }
                    Text((try? AttributedString(markdown: parts.detail)) ?? AttributedString(parts.detail))
                        .font(parts.title == nil ? SG.Font.body : SG.Font.field)
                        .foregroundStyle(parts.title == nil ? SG.Ink.primary : SG.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 26)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Il colore accompagna il titolo e il simbolo: non è mai l'unico segnale.
    private var tint: Color {
        switch section.title.lowercased() {
        case "novità", "new features": Palette.calm
        case "correzioni", "bug fixes": .orange
        case "sicurezza", "security": .red
        default: accent.base
        }
    }

    /// I nomi dei gruppi come nelle note di rilascio: in inglese, in ogni lingua dell'app.
    static func executiveTitle(_ title: String) -> String {
        switch title.lowercased() {
        case "novità", "new features": "New features"
        case "miglioramenti", "improvements": "Improvements"
        case "correzioni", "bug fixes": "Bug fixes"
        case "sicurezza", "security": "Security"
        case "problemi noti", "known issues": "Known issues"
        default: title
        }
    }

    /// "**Titolo.** Dettaglio" → titolo e dettaglio; senza grassetto in testa, tutta la riga è il dettaglio.
    static func split(_ item: String) -> (title: String?, detail: String) {
        guard item.hasPrefix("**") else { return (nil, item) }
        let rest = item.dropFirst(2)
        guard let end = rest.range(of: "**") else { return (nil, item) }
        var title = String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
        if title.hasSuffix(".") { title.removeLast() }
        let detail = rest[end.upperBound...].trimmingCharacters(in: .whitespaces)
        return (title, detail)
    }
}
