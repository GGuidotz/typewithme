// La scheda Personalizzazione: la cronologia di scrittura (cosa si registra, quanto pesa sulla scelta delle parole) e lo
// sheet per vederla ed eliminarla, per app o tutta. I testi stanno cifrati sul Mac (Sources/App/TypingHistory.swift).

import SwiftUI

struct PersonalizationSettings: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var history: TypingHistory
    @State private var showHistory = false

    var body: some View {
        SGPage {
            SGSection(L("Cronologia di scrittura")) {
                SGToggleRow(L("Registra quello che scrivo per personalizzare i suggerimenti"), isOn: $prefs.recordHistory)
                SGDivider()
                SGToggleRow(L("Registra anche dove non accetto suggerimenti"), isOn: $prefs.recordWithoutAccepting)
                    .disabled(!prefs.recordHistory)
                SGDivider()
                SGLabeledRow {
                    Text(L("Testi registrati"))
                } trailing: {
                    HStack(spacing: 10) {
                        Text(Format.integer(history.count))
                            .font(SG.Font.value)
                            .foregroundStyle(SG.Ink.secondary)
                            .lineLimit(1)
                            .fixedSize()
                        Button(L("Mostra la cronologia")) { showHistory = true }
                            .buttonStyle(.sgSecondary)
                    }
                }
            } footer: {
                SGFootnote(L("Il testo resta sul Mac, cifrato; la chiave sta nel Portachiavi. Non si registra nei campi password né nelle app escluse. Sconsigliato se lavori con informazioni molto riservate."))
            }

            InstructionsSection(prefs: prefs)

            SGSection(L("Stile")) {
                SGRowBlock {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(L("Scelta delle parole"), selection: $prefs.wordChoice) {
                            Text(L("Spenta")).tag(0)
                            Text(L("Leggera")).tag(1)
                            Text(L("Media")).tag(2)
                            Text(L("Forte")).tag(3)
                        }
                        .pickerStyle(.segmented)
                        SGFootnote(L("Impara dalla cronologia le parole che scrivi di solito e le propone quando battono quelle del modello. Più è forte, più contano le tue parole; troppo forte può proporre parole meno adatte."))
                    }
                }
            }
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet(history: history)
                .sguardoAccent(default: .typewithme)
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
                        .buttonStyle(.sgSecondary)
                }
                Spacer()
                Button(L("Fine")) { dismiss() }
                    .buttonStyle(.sgPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            if let selected {
                AppEntries(history: history, bundleID: selected) { self.selected = nil }
            } else {
                appList
            }
            if selected == nil {
                HStack {
                    Spacer()
                    Button(L("Elimina tutto"), role: .destructive) { confirmAll = true }
                        .buttonStyle(.sgDestructive)
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
                .font(SG.Font.body)
                .foregroundStyle(SG.Ink.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                SGGroup {
                    ForEach(Array(apps.enumerated()), id: \.element.bundleID) { index, app in
                        if index > 0 { SGDivider() }
                        HStack(spacing: SG.Space.m) {
                            Button { selected = app.bundleID } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.appName).font(SG.Font.body).foregroundStyle(SG.Ink.primary)
                                    Text(L("%@ testi, %@ caratteri", Format.integer(app.count), Format.integer(app.characters)))
                                        .font(SG.Font.caption).monospacedDigit().foregroundStyle(SG.Ink.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button(L("Elimina"), role: .destructive) { history.delete(bundleID: app.bundleID) }
                                .buttonStyle(.sgDestructive)
                                .accessibilityLabel(L("Elimina i testi di %@", app.appName))
                        }
                        .padding(.horizontal, SG.Space.rowInset)
                        .padding(.vertical, 8)
                        .frame(minHeight: SG.Size.row)
                    }
                }
                .padding(.horizontal, SG.Space.contentPadding)
                .padding(.bottom, SG.Space.contentPadding)
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
                    .font(SG.Font.body)
                    .foregroundStyle(SG.Ink.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    SGGroup {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { SGDivider() }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.date.formatted(.dateTime.day().month().year().hour().minute().locale(Localization.locale)))
                                    .font(SG.Font.caption).monospacedDigit().foregroundStyle(SG.Ink.secondary)
                                Text(entry.text).font(SG.Font.body).foregroundStyle(SG.Ink.primary).lineLimit(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, SG.Space.rowInset)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, SG.Space.contentPadding)
                    .padding(.bottom, SG.Space.contentPadding)
                }
            }
            HStack {
                Spacer()
                Button(L("Elimina i testi di questa app"), role: .destructive) {
                    history.delete(bundleID: bundleID)
                    back()
                }
                .buttonStyle(.sgDestructive)
                .disabled(entries.isEmpty)
            }
            .padding(12)
        }
    }
}
