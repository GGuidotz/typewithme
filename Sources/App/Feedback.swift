// Feedback, come in Nod e in Cocaine: segnalare un problema o proporre un'idea su GitHub (il canale preferito, pubblico),
// oppure scrivere un'email con in fondo i dati che servono (versione, macOS, modello del Mac, lingua). Il report di
// diagnostica si copia o si salva da allegare. Più il pannello Informazioni su Type_w/Me.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Developer {
    static let name = "gguidotz"
    static let repo = AppInfo.repo
    static let github = URL(string: "https://github.com/\(AppInfo.repo)")!
    static let issues = URL(string: "https://github.com/\(AppInfo.repo)/issues")!
    static let email = "giulioguidotz@yahoo.com"
}

@MainActor
enum Feedback {
    enum Kind {
        case problem, idea

        var template: String { self == .problem ? "bug_report.yml" : "feature_request.yml" }
    }

    /// Una nuova issue su GitHub con il modello giusto e i dati del Mac già scritti.
    static func openIssue(_ kind: Kind) {
        var c = URLComponents(url: Developer.github.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "template", value: kind.template),
                         URLQueryItem(name: "environment", value: SystemInfo.oneLine)]
        if let url = c?.url { NSWorkspace.shared.open(url) }
        diag(.feedback, kind == .problem ? "opened a problem report" : "opened an idea")
    }

    /// Una nuova email nell'app di posta, con i dati del Mac in fondo (come il pulsante di Cocaine).
    static func composeEmail() {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = Developer.email
        c.queryItems = [URLQueryItem(name: "subject", value: "\(AppInfo.name) \(SystemInfo.version) – " + L("Feedback")),
                        URLQueryItem(name: "body", value: "\n\n\n— \(SystemInfo.oneLine)")]
        if let url = c.url { NSWorkspace.shared.open(url) }
        diag(.feedback, "email composed")
    }

    static func copyReport(model: AppModel) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DiagnosticsReport.make(model: model), forType: .string)
        diag(.feedback, "report copied")
    }

    /// Salva il report e lo mostra nel Finder. Restituisce un messaggio per chi usa l'app.
    static func saveReport(model: AppModel) -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DiagnosticsReport.suggestedFileName
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try DiagnosticsReport.make(model: model).write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return L("Salvato: %@", url.lastPathComponent)
        } catch {
            return error.localizedDescription
        }
    }
}

enum AboutPanel {
    @MainActor
    static func show() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: center,
                                                   .foregroundColor: NSColor.secondaryLabelColor]
        let credits = NSMutableAttributedString(string: L("Il seguito di quello che scrivi, in ogni app del Mac.") + "\n\n", attributes: base)
        credits.append(NSAttributedString(string: L("Sviluppato da %@", Developer.name) + "\n", attributes: base))
        var link = base
        link[.link] = Developer.github
        credits.append(NSAttributedString(string: "github.com/\(Developer.repo)\n", attributes: link))
        link[.link] = URL(string: "mailto:\(Developer.email)")
        credits.append(NSAttributedString(string: Developer.email, attributes: link))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

/// Firma dello sviluppatore, riusata nelle impostazioni.
struct DeveloperLinks: View {
    var body: some View {
        HStack(spacing: 14) {
            Text(L("Sviluppato da %@", Developer.name)).foregroundStyle(SG.Ink.secondary)
            Link(destination: Developer.github) { Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
            Link(destination: URL(string: "mailto:\(Developer.email)")!) { Label(Developer.email, systemImage: "envelope") }
        }
        .font(SG.Font.field)
    }
}
