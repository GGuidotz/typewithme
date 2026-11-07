// La scheda Personalizzazione: la cronologia di scrittura (cosa si registra, quanto pesa sulla scelta delle parole) e lo
// sheet per vederla ed eliminarla, per app o tutta. I testi stanno cifrati sul Mac (Sources/App/TypingHistory.swift).

import SwiftUI

struct PersonalizationSettings: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var history: TypingHistory
    @State private var showHistory = false

    var body: some View {
        Form {
            Section {
                Toggle(L("Registra quello che scrivo per personalizzare i suggerimenti"), isOn: $prefs.recordHistory)
                Toggle(L("Registra anche dove non accetto suggerimenti"), isOn: $prefs.recordWithoutAccepting)
                    .disabled(!prefs.recordHistory)
                LabeledContent(L("Testi registrati")) {
                    HStack(spacing: 10) {
                        Text(Format.integer(history.count)).monospacedDigit().foregroundStyle(.secondary)
                        Button(L("Mostra la cronologia")) { showHistory = true }
                    }
                }
            } header: {
                Text(L("Cronologia di scrittura"))
            } footer: {
                Footnote(L("Il testo resta sul Mac, cifrato; la chiave sta nel Portachiavi. Non si registra nei campi password né nelle app escluse. Sconsigliato se lavori con informazioni molto riservate."))
            }

            InstructionsSection(prefs: prefs)

            Section {
                Picker(L("Scelta delle parole"), selection: $prefs.wordChoice) {
                    Text(L("Spenta")).tag(0)
                    Text(L("Leggera")).tag(1)
                    Text(L("Media")).tag(2)
                    Text(L("Forte")).tag(3)
                }
                .pickerStyle(.segmented)
                Footnote(L("Impara dalla cronologia le parole che scrivi di solito e le propone quando battono quelle del modello. Più è forte, più contano le tue parole; troppo forte può proporre parole meno adatte."))
            } header: {
                Text(L("Stile"))
            }
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet(history: history)
        }
    }
}

/// L'elenco per app e, scelta un'app, le sue voci più recenti.
private struct HistorySheet: View {
    @ObservedObject var history: TypingHistory
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var confirmAll = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if selected != nil {
                    Button(L("Indietro")) { selected = nil }
                }
                Spacer()
                Button(L("Fine")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            if let selected {
                AppEntries(history: history, bundleID: selected) { self.selected = nil }
            } else {
                appList
            }
            if selected == nil {
                Divider()
                HStack {
                    Spacer()
                    Button(L("Elimina tutto"), role: .destructive) { confirmAll = true }
                        .disabled(history.count == 0)
                }
                .padding(12)
            }
        }
        .frame(width: 460, height: 440)
        .confirmationDialog(L("Eliminare tutta la cronologia?"), isPresented: $confirmAll, titleVisibility: .visible) {
            Button(L("Elimina tutto"), role: .destructive) { history.deleteAll(); selected = nil }
            Button(L("Non eliminare"), role: .cancel) {}
        } message: {
            Text(L("I testi registrati vengono cancellati dal Mac e non si possono recuperare."))
        }
    }

    @ViewBuilder private var appList: some View {
        let apps = history.apps
        if apps.isEmpty {
            Text(L("Nessun testo registrato."))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(apps, id: \.bundleID) { app in
                HStack {
                    Button { selected = app.bundleID } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.appName)
                            Text(L("%@ testi, %@ caratteri", Format.integer(app.count), Format.integer(app.characters)))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button(L("Elimina"), role: .destructive) { history.delete(bundleID: app.bundleID) }
                        .accessibilityLabel(L("Elimina i testi di %@", app.appName))
                }
            }
        }
    }
}

/// Le voci di un'app, le più recenti per prime, al massimo 200.
private struct AppEntries: View {
    @ObservedObject var history: TypingHistory
    var bundleID: String
    var back: () -> Void

    var body: some View {
        let entries = Array(history.entries.filter { $0.bundleID == bundleID }.reversed().prefix(200))
        VStack(spacing: 0) {
            if entries.isEmpty {
                Text(L("Nessun testo registrato."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.date.formatted(.dateTime.day().month().year().hour().minute().locale(Localization.locale)))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Text(entry.text).lineLimit(3)
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(L("Elimina i testi di questa app"), role: .destructive) {
                    history.delete(bundleID: bundleID)
                    back()
                }
                .disabled(entries.isEmpty)
            }
            .padding(12)
        }
    }
}
