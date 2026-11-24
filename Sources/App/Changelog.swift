// Le novità, lette dal CHANGELOG.md incluso nell'app (Contents/Resources) o da quello su GitHub (aggiornamenti).
// Formato:
//   ## 0.4.0 · 2026-10-13
//   ### Novità
//   - **Titolo breve.** Una riga per cambiamento, scritta per chi usa l'app.
// La riga semplice sotto il titolo della versione è il riassunto (la schermata Novità la mette in testa); il titolo in
// grassetto di una voce è quello che la schermata mostra in evidenza.
// Sezioni previste: Novità, Miglioramenti, Correzioni, Sicurezza, Problemi noti (vanno bene anche i nomi inglesi).
// Le righe prima di una sezione vanno in "Cambiamenti". Stesso schema di Nod.

import Foundation
import SwiftUI

struct ChangelogSection: Identifiable, Equatable {
    let title: String
    let items: [String]
    var id: String { title }

    var symbol: String {
        switch title.lowercased() {
        case "novità", "new features": "sparkles"
        case "miglioramenti", "improvements": "arrow.up.circle"
        case "correzioni", "bug fixes": "ladybug"
        case "sicurezza", "security": "lock.shield"
        case "problemi noti", "known issues": "exclamationmark.triangle"
        default: "circle.grid.2x1"
        }
    }
}

struct ChangelogEntry: Identifiable, Equatable {
    let version: String
    let date: String
    let sections: [ChangelogSection]
    /// La frase sotto il titolo della versione.
    var summary = ""
    var id: String { version }
}

enum Changelog {
    /// Le note nella lingua dell'app: in inglese quelle di CHANGELOG.en.md, e le versioni che lì mancano in italiano.
    static func load(bundle: Bundle = .main) -> [ChangelogEntry] {
        func read(_ name: String) -> [ChangelogEntry] {
            guard let url = bundle.url(forResource: name, withExtension: "md"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return parse(text)
        }
        let italian = read("CHANGELOG")
        guard Localization.effectiveCode.hasPrefix("en") else { return italian }
        let english = Dictionary(read("CHANGELOG.en").map { ($0.version, $0) }, uniquingKeysWith: { first, _ in first })
        return italian.map { english[$0.version] ?? $0 }
    }

    static func parse(_ text: String) -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        var version: String?, date = "", summary = ""
        var sections: [ChangelogSection] = []
        var sectionTitle = "Cambiamenti", items: [String] = []

        func flushSection() {
            if !items.isEmpty { sections.append(ChangelogSection(title: sectionTitle, items: items)) }
            items = []
        }
        func flushEntry() {
            flushSection()
            if let version {
                entries.append(ChangelogEntry(version: version, date: date, sections: sections, summary: summary))
            }
            sections = []
            summary = ""
            sectionTitle = "Cambiamenti"
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flushEntry()
                let parts = line.dropFirst(3).components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
                version = parts.first
                date = parts.count > 1 ? parts[1] : ""
            } else if line.hasPrefix("### "), version != nil {
                flushSection()
                sectionTitle = String(line.dropFirst(4))
            } else if line.hasPrefix("- "), version != nil {
                items.append(String(line.dropFirst(2)))
            } else if !line.isEmpty, !line.hasPrefix("#"), version != nil, !items.isEmpty {
                items[items.count - 1] += " " + line          // una voce che continua sulla riga dopo
            } else if !line.isEmpty, !line.hasPrefix("#"), version != nil, sections.isEmpty, sectionTitle == "Cambiamenti" {
                summary += summary.isEmpty ? line : " " + line
            }
        }
        flushEntry()
        return entries
    }

    /// Le versioni dopo `seen` fino a `current` compresa, dalla più recente.
    static func entries(after seen: String, upTo current: String, in all: [ChangelogEntry]) -> [ChangelogEntry] {
        all.filter { Version($0.version) > Version(seen) && Version($0.version) <= Version(current) }
    }
}

/// Le novità a schermo: un blocco per versione, con le sezioni e il loro simbolo.
struct ChangelogList: View {
    let entries: [ChangelogEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(L("Versione %@", entry.version)).font(SG.Font.bodyEmphasis).foregroundStyle(SG.Ink.primary)
                        Text(entry.date).font(SG.Font.caption).foregroundStyle(SG.Ink.secondary)
                    }
                    ForEach(entry.sections) { section in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(section.title, systemImage: section.symbol)
                                .font(SG.Font.label)
                                .foregroundStyle(SG.Ink.secondary)
                            ForEach(section.items, id: \.self) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(SG.Ink.tertiary).accessibilityHidden(true)
                                    Text((try? AttributedString(markdown: item)) ?? AttributedString(item))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(SG.Font.field)
                                .foregroundStyle(SG.Ink.primary)
                            }
                        }
                    }
                }
            }
        }
    }
}
