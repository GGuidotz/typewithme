// Impostazioni (⌘,): sei schede sotto una barra di vetro che galleggia. Solo ciò che si cambia di rado, più
// aggiornamenti e feedback, come nelle altre app della famiglia. In cima a Generale la vista compatta dello stato
// (Sources/Island); la scheda Motori sta in Sources/App/EngineSettings.swift.

import AppKit
import SwiftUI

struct SettingsView: View {
    static let size = CGSize(width: 620, height: 680)

    @ObservedObject var model: AppModel
    @ObservedObject var prefs: Preferences

    init(model: AppModel) {
        self.model = model
        prefs = model.prefs
    }

    var body: some View {
        Group {
            switch model.settingsTab {
            case .general: GeneralSettings(model: model, prefs: prefs, completer: model.completer)
            case .suggestions: SuggestionSettings(prefs: prefs, completer: model.completer)
            case .apps: AppsSettings(prefs: prefs, completer: model.completer)
            case .personalization: PersonalizationSettings(prefs: prefs, history: model.completer.history)
            case .engines: EngineSettings(prefs: prefs, completer: model.completer, llama: model.completer.llama)
            case .updates: UpdatesSettings(updater: model.updater, prefs: prefs)
            case .feedback: FeedbackSettings(model: model)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)   // il fondo è il materiale della finestra (SettingsWindow)
        .safeAreaInset(edge: .top, spacing: 0) {
            SettingsTabBar(selection: $model.settingsTab)
                .padding(.top, 2)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .id(prefs.language)   // cambio di lingua: ridisegna tutto subito
    }
}

/// Il testo sotto una sezione.
struct Footnote: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Generale

private struct GeneralSettings: View {
    var model: AppModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var completer: Completer
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?
    @State private var usage: ProcessUsage?
    @State private var accessibility = Permissions.accessibility
    @State private var inputMonitoring = Permissions.inputMonitoring
    @State private var cotypistStats: CotypistImport.Stats?

    var body: some View {
        Form {
            Section {
                TypeWithMeStatusView(info: completer.statusInfo, labels: .localized)
            }

            if let stats = cotypistStats {
                Section {
                    Text(L("Cotypist ha contato %@ parole accettate in %d giorni.", Format.integer(stats.words), stats.days))
                    Button(prefs.cotypistImported ? L("Già aggiunte al contatore") : L("Aggiungi al contatore di Type_w/Me")) {
                        prefs.acceptedWordsTotal += stats.words
                        prefs.cotypistImported = true
                        diag(.app, "cotypist stats imported")
                    }
                    .disabled(prefs.cotypistImported)
                } header: {
                    Text(L("Da Cotypist"))
                } footer: {
                    Footnote(L("Le memorie di Cotypist sono cifrate e non si possono importare. Il suo modello Gemma 3 1B base, se c'è, compare già nel catalogo di Impostazioni › Motori e si usa senza scaricare nulla."))
                }
            }

            Section {
                Toggle(L("Suggerimenti attivi"), isOn: Binding(get: { prefs.enabled }, set: { completer.setEnabled($0) }))
                Toggle(L("Apri all'accesso"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in
                        loginError = LaunchAtLogin.set(enabled)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                ))
                if let loginError { Footnote(loginError) }
                Picker(L("Lingua"), selection: $prefs.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Footnote(L("La lingua è quella dell'interfaccia di Type_w/Me. I suggerimenti seguono la lingua in cui stai scrivendo."))
            }

            Section {
                PermissionRow(title: L("Accessibilità"), granted: accessibility,
                              detail: L("Per leggere il campo in cui scrivi, mostrare il suggerimento e vedere Tab ed Esc."),
                              request: { Permissions.requestAccessibility() }, open: { Permissions.openAccessibilitySettings() })
                PermissionRow(title: L("Monitoraggio input"), granted: inputMonitoring,
                              detail: L("Su alcune versioni di macOS serve anche questo per vedere i tasti. Se i suggerimenti funzionano, puoi ignorarlo."),
                              request: { Permissions.requestInputMonitoring() }, open: { Permissions.openInputMonitoringSettings() })
            } header: {
                Text(L("Permessi"))
            } footer: {
                Footnote(L("Niente esce dal Mac: i permessi servono solo a leggere il campo con il fuoco e a scriverci. Dopo averli concessi, se la voce nella barra resta chiara, riapri Type_w/Me."))
            }
            .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
                accessibility = Permissions.accessibility
                inputMonitoring = Permissions.inputMonitoring
                if accessibility, !completer.monitor.isRunning { completer.startMonitorIfPossible() }
            }

            Section {
                LabeledContent(L("Consumo di Type_w/Me")) {
                    Text(usage.map { L("%@ di CPU · %@", Format.percent($0.cpu), Format.bytes($0.memory)) } ?? "–")
                        .monospacedDigit()
                }
                Button(L("Rivedi la guida iniziale")) { model.showOnboarding() }
            } footer: {
                Footnote(L("A tastiera ferma l'app non fa nulla. Il modello lavora solo dopo una pausa mentre scrivi, e si ferma appena riprendi."))
            }
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in usage = completer.ownUsage }
            .onAppear { cotypistStats = CotypistImport.readStats() }
            .onAppear { usage = completer.ownUsage }
        }
    }
}

extension TypeWithMeStatusLabels {
    /// I testi della vista compatta nella lingua scelta per l'app.
    static var localized: TypeWithMeStatusLabels {
        var labels = TypeWithMeStatusLabels()
        labels.engine = L("Motore")
        labels.today = L("Parole oggi")
        labels.total = L("Da sempre")
        labels.session = L("Accettati")
        labels.response = L("Risposta")
        labels.milliseconds = L("%d ms")
        labels.acceptedOfShown = L("%d su %d")
        return labels
    }
}

/// Una riga di permesso: nome, stato scritto e colorato, pulsanti per chiedere o aprire le impostazioni.
struct PermissionRow: View {
    var title: String
    var granted: Bool
    var detail: String
    var request: () -> Void
    var open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(granted ? Palette.calm : Color.orange)
                }
                Spacer()
                if granted {
                    Text(L("Concesso")).foregroundStyle(.secondary)
                } else {
                    Button(L("Consenti")) { request() }
                    Button(L("Apri Impostazioni di Sistema")) { open() }
                }
            }
            Footnote(detail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(granted ? L("Concesso") : L("Non concesso"))
    }
}

// MARK: - Suggerimenti

private struct SuggestionSettings: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var completer: Completer
    @State private var forgotten = false

    var body: some View {
        Form {
            Section {
                GhostPreview(written: L("Ci vediamo domani alle"), ghost: L(" 10 davanti all'ufficio."),
                             accept: L("%@ accetta una parola, %@ tutto, %@ scarta.", prefs.acceptWord.display, prefs.acceptAll.display, prefs.dismiss.display))
                KeyBindingRecorder(title: L("Accetta una parola"), binding: $prefs.acceptWord, reset: .tab)
                KeyBindingRecorder(title: L("Accetta tutto"), binding: $prefs.acceptAll, reset: .shiftTab)
                KeyBindingRecorder(title: L("Scarta"), binding: $prefs.dismiss, reset: .escape)
                KeyBindingRecorder(title: L("Riscrivi la selezione"), binding: $prefs.rewrite, reset: .controlOptionR)
                KeyBindingRecorder(title: L("Correggi il paragrafo"), binding: $prefs.proofread, reset: .controlOptionG)
                KeyBindingRecorder(title: L("Sinonimi della selezione"), binding: $prefs.synonyms, reset: .controlOptionS)
            } header: {
                Text(L("Tasti"))
            } footer: {
                Footnote(L("I tasti di accettazione valgono solo mentre un suggerimento è visibile: senza suggerimento Tab ed Esc fanno quello che fanno sempre. Se continui a scrivere, il suggerimento sparisce da solo."))
            }

            Section {
                WordLimitSlider(prefs: prefs)
                LabeledContent(L("Aspetta prima di suggerire")) {
                    HStack(spacing: 10) {
                        Slider(value: $prefs.delay, in: 0.05...1.0, step: 0.01)
                            .frame(width: 180)
                            .accessibilityLabel(L("Aspetta prima di suggerire"))
                            .accessibilityValue(L("%d ms", Int(prefs.delay * 1000)))
                        Text(L("%d ms", Int(prefs.delay * 1000)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                Toggle(L("Completa anche a metà riga (sperimentale)"), isOn: $prefs.midLine)
                Toggle(L("Niente suggerimenti se la parola sembra sbagliata"), isOn: $prefs.hideOnTypo)
                Toggle(L("A batteria, risparmia energia"), isOn: $prefs.batterySaver)
            } header: {
                Text(L("Quando e quanto"))
            } footer: {
                Footnote(L("Il suggerimento arriva dopo una pausa nella scrittura. A metà riga il seguito deve raccordarsi con il testo che c'è dopo il cursore: funziona, ma non sempre bene. Con una parola che sembra sbagliata il suggerimento la allungherebbe con l'errore: meglio niente. A batteria la pausa si allunga della metà, lo schermo non si legge e il modello si spegne dopo i minuti di inattività scelti in Motori."))
            }

            Section {
                Toggle(L("Sottolinea gli errori mentre scrivo"), isOn: $prefs.proofreading)
                Toggle(L("Controlla anche la grammatica con Apple Intelligence"), isOn: $prefs.grammarCheck)
                    .disabled(!prefs.proofreading)
                if !prefs.learnedWords.isEmpty {
                    HStack {
                        Text(L("%@ parole ignorate", Format.integer(prefs.learnedWords.count))).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Segnala di nuovo")) {
                            prefs.learnedWords = []
                            SpellGuard.learned = []
                        }
                    }
                }
            } header: {
                Text(L("Correttore"))
            } footer: {
                Footnote(L("Quando ti fermi un attimo il paragrafo si controlla: l'ortografia subito, in italiano e in inglese insieme (i termini inglesi in una frase italiana non sono errori); la grammatica a frase finita, con Apple Intelligence sul Mac. Gli errori si sottolineano (rosso ortografia, blu grammatica); %@ apre le correzioni, Invio le applica. Con del testo selezionato la stessa scorciatoia lo corregge in Riscrivi.", prefs.proofread.display))
            }

            Section {
                Toggle(L("Correzioni italiane in linea"), isOn: $prefs.italianCorrections)
                Toggle(L("Maiuscola dopo il punto"), isOn: $prefs.capitalizeSentences)
                    .disabled(!prefs.italianCorrections)
            } header: {
                Text(L("Correzioni"))
            } footer: {
                Footnote(L("Appena finisci la parola: \"perche\" diventa \"perché\", \"un pò\" diventa \"un po'\", \"qual'è\" diventa \"qual è\". Solo parole che sbagliate non vogliono dire niente; le sigle in maiuscolo non si toccano."))
            }

            AbbreviationSection(prefs: prefs)

            Section {
                Toggle(L("Ricorda le frasi che accetto"), isOn: $prefs.phraseMemory)
                HStack {
                    Text(L("%@ seguiti ricordati", Format.integer(completer.memory.count))).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Dimentica tutto")) {
                        completer.forgetPhrases()
                        forgotten = true
                    }
                    .disabled(completer.memory.count == 0)
                }
                if forgotten { Footnote(L("Memoria svuotata.")) }
            } header: {
                Text(L("Memoria delle frasi"))
            } footer: {
                Footnote(L("I seguiti che accetti vengono legati alle due parole che li precedono e riproposti subito, senza modello, dalla seconda volta. Restano in un file sul Mac, in Application Support."))
            }
        }
    }
}

/// Le abbreviazioni: una riga per sigla, e in fondo quella per aggiungerne una.
private struct AbbreviationSection: View {
    @ObservedObject var prefs: Preferences
    @State private var newTrigger = ""
    @State private var newExpansion = ""

    var body: some View {
        Section {
            ForEach($prefs.abbreviations) { $item in
                HStack(spacing: 8) {
                    TextField(text: $item.trigger) { Text(L("Sigla")) }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                    TextField(text: $item.expansion) { Text(L("Testo intero")) }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    Button { removeAbbreviation(item.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L("Togli l'abbreviazione %@", item.trigger))
                }
            }
            HStack(spacing: 8) {
                TextField(text: $newTrigger, prompt: Text(L("Per esempio: ;firma"))) { Text(L("Sigla")) }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                TextField(text: $newExpansion, prompt: Text(L("Per esempio: Cordiali saluti, Marta Rossi"))) { Text(L("Testo intero")) }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addAbbreviation() }
                Button(L("Aggiungi")) { addAbbreviation() }
                    .disabled(newAbbreviation == nil)
            }
            if newAbbreviation == nil, let why = abbreviationProblem { Footnote(why) }
        } header: {
            Text(L("Abbreviazioni"))
        } footer: {
            Footnote(L("Scrivi la sigla e poi uno spazio o un segno: diventa il testo intero (\"cmq\" diventa \"comunque\"). Usa sigle che non scriveresti mai per conto tuo, o mettici davanti un punto e virgola (;firma): una parola vera verrebbe sostituita ogni volta. Maiuscole comprese, niente a capo."))
        }
    }

    /// L'abbreviazione da aggiungere, se si può: sigla senza spazi e non già usata, testo non vuoto.
    private var newAbbreviation: Abbreviation? {
        let trigger = newTrigger.trimmingCharacters(in: .whitespaces)
        let item = Abbreviation(trigger: trigger, expansion: Abbreviations.clean(newExpansion))
        guard item.isUsable, !prefs.abbreviations.contains(where: { $0.trigger == trigger }) else { return nil }
        return item
    }

    /// Perché non si può aggiungere, quando hai già scritto qualcosa.
    private var abbreviationProblem: String? {
        let trigger = newTrigger.trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty else { return nil }
        if trigger.contains(where: { $0.isWhitespace }) { return L("La sigla non può contenere spazi.") }
        if prefs.abbreviations.contains(where: { $0.trigger == trigger }) { return L("Questa sigla c'è già.") }
        return nil
    }

    private func addAbbreviation() {
        guard let item = newAbbreviation else { return }
        prefs.abbreviations.append(item)
        newTrigger = ""
        newExpansion = ""
    }

    private func removeAbbreviation(_ id: UUID) {
        prefs.abbreviations.removeAll { $0.id == id }
    }
}

// MARK: - App

private struct AppsSettings: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var completer: Completer
    @State private var running: [NSRunningApplication] = []

    var body: some View {
        Form {
            Section {
                Toggle(L("Usa l'app in cui scrivi come contesto"), isOn: $prefs.appContext)
                Toggle(L("Usa gli appunti come contesto"), isOn: $prefs.clipboardContext)
                Toggle(L("Usa lo schermo come contesto"), isOn: Binding(
                    get: { prefs.screenContext },
                    set: { on in
                        prefs.screenContext = on
                        if on, !ScreenContext.hasPermission { ScreenContext.requestPermission() }
                    }))
                if prefs.screenContext, !ScreenContext.hasPermission {
                    HStack {
                        Text(L("Serve il permesso Registrazione schermo.")).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Apri Impostazioni di Sistema")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } header: {
                Text(L("Contesto"))
            } footer: {
                Footnote(L("Con l'app il modello legge con Accessibilità il titolo e il testo della finestra in cui scrivi (la mail o la chat a cui rispondi, la pagina), senza il campo in cui scrivi, al più ogni pochi secondi: niente permessi in più. Con gli appunti il modello vede anche l'ultima cosa che hai copiato (nomi, numeri, indirizzi) e la usa se c'entra. Con lo schermo legge il testo della finestra in cui scrivi (una mail a cui rispondi, una pagina), riconosciuto sul Mac, al più ogni pochi secondi e mai a ogni tasto; il testo resta in memoria e non si salva. Spenti, appunti e schermo non vengono letti mai. Dopo aver concesso il permesso può servire riaprire l'app."))
            }

            Section {
                ForEach(prefs.excludedApps.sorted(by: { name(for: $0) < name(for: $1) }), id: \.self) { bundleID in
                    HStack {
                        Text(name(for: bundleID))
                        Text(bundleID).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer()
                        Button {
                            prefs.setExcluded(bundleID, false)
                            completer.refreshStatus()
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L("Togli %@ dalle escluse", name(for: bundleID)))
                    }
                }
                Menu(L("Aggiungi un'app aperta…")) {
                    ForEach(running.filter { !prefs.excludedApps.contains($0.bundleIdentifier ?? "") }, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                            if let id = app.bundleIdentifier { prefs.setExcluded(id, true); completer.refreshStatus() }
                        }
                    }
                }
                .onAppear { refreshRunning() }
                Button(L("Torna all'elenco di partenza")) { prefs.resetExclusions(); completer.refreshStatus() }
            } header: {
                Text(L("App escluse"))
            } footer: {
                Footnote(L("Qui Type_w/Me non legge e non scrive mai. Nei campi password e con l'input sicuro acceso non lo fa comunque, in nessuna app. Dal menu nella barra puoi spegnere l'app in cui ti trovi."))
            }

            AppInstructionsSection(prefs: prefs, running: running)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refreshRunning() }
    }

    private func refreshRunning() {
        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func name(for bundleID: String) -> String { AppNames.name(for: bundleID) }
}

/// Le istruzioni per app: una frase per app, i profili consigliati da accettare con un pulsante.
private struct AppInstructionsSection: View {
    @ObservedObject var prefs: Preferences
    var running: [NSRunningApplication]

    var body: some View {
        Section {
            ForEach(sortedIDs, id: \.self) { bundleID in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(AppNames.name(for: bundleID))
                        Text(bundleID).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer()
                        Button { prefs.appInstructions[bundleID] = nil } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L("Togli le istruzioni per %@", AppNames.name(for: bundleID)))
                    }
                    TextField(text: binding(for: bundleID), prompt: Text(L("Per esempio: tono formale, frasi complete"))) {
                        Text(AppNames.name(for: bundleID))
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Menu(L("Aggiungi un'app aperta…")) {
                    ForEach(addable, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                            if let id = app.bundleIdentifier { prefs.appInstructions[id] = "" }
                        }
                    }
                }
                if AppProfiles.canAddRecommended(to: prefs.appInstructions) {
                    Button(L("Usa i profili consigliati")) {
                        prefs.appInstructions = AppProfiles.merged(into: prefs.appInstructions)
                    }
                }
            }
        } header: {
            Text(L("Istruzioni per app"))
        } footer: {
            Footnote(L("Una frase per il modello che vale solo in quell'app, dopo le tue istruzioni generali. I profili consigliati: Mail formale e cortese, Messaggi informale e breve, Note neutro e sintetico; non sono attivi finché non li accetti. Restano sul Mac."))
        }
    }

    private var sortedIDs: [String] {
        prefs.appInstructions.keys.sorted { AppNames.name(for: $0) < AppNames.name(for: $1) }
    }

    private var addable: [NSRunningApplication] {
        var out: [NSRunningApplication] = []
        for app in running {
            guard let id = app.bundleIdentifier, prefs.appInstructions[id] == nil else { continue }
            out.append(app)
        }
        return out
    }

    private func binding(for bundleID: String) -> Binding<String> {
        Binding(get: { prefs.appInstructions[bundleID] ?? "" },
                set: { prefs.appInstructions[bundleID] = $0 })
    }
}

/// Il nome di un'app dal suo bundle id: quello del Finder se è installata, altrimenti uno che conosciamo.
@MainActor
enum AppNames {
    static func name(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        if let known = Exclusions.knownNames[bundleID] { return known }
        if let profile = AppProfiles.recommended.first(where: { $0.bundleID == bundleID }) { return profile.name }
        return bundleID
    }
}

// MARK: - Aggiornamenti

private struct UpdatesSettings: View {
    @ObservedObject var updater: Updater
    @ObservedObject var prefs: Preferences
    private let current = Changelog.load().first

    var body: some View {
        Form {
            Section {
                Toggle(L("Controlla automaticamente (ogni 6 ore)"), isOn: $prefs.autoCheckUpdates)
                LabeledContent(L("Versione installata"), value: updater.currentVersion)
                LabeledContent(L("Ultimo controllo")) {
                    if let last = updater.lastCheck { Text(last, style: .relative) } else { Text(L("Mai")) }
                }
                HStack {
                    Button(L("Controlla ora")) { Task { await updater.check() } }
                        .disabled(updater.state == .checking)
                    UpdateStateText(updater: updater)
                }
            }

            if updater.isUpdateAvailable {
                Section { UpdateCard(updater: updater) }
            }

            if let current {
                Section {
                    ChangelogList(entries: [current])
                    Button(L("Mostra la schermata delle novità")) { AppModel.shared.showWhatsNew() }
                } header: {
                    Text(L("Novità di questa versione"))
                }
            }
        }
    }
}

private struct UpdateStateText: View {
    @ObservedObject var updater: Updater

    var body: some View {
        switch updater.state {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .upToDate:
            Label(L("Type_w/Me è aggiornato."), systemImage: "checkmark.circle.fill").foregroundStyle(Palette.calm)
        case .available(let version):
            Label(L("Disponibile la versione %@", version), systemImage: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
        case .failed(let why):
            Text(why).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Le novità della nuova versione e il comando per aggiornare.
private struct UpdateCard: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .available(let version) = updater.state {
                Label(L("Disponibile Type_w/Me %@", version), systemImage: "arrow.down.circle.fill")
                    .font(.headline)
            }
            if !updater.news.isEmpty { ChangelogList(entries: updater.news) }
            Text(L("Per aggiornare, esegui nel Terminale:")).foregroundStyle(.secondary)
            Text(updater.command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
            HStack {
                Button(L("Copia comando")) { updater.copyCommand() }
                Button(L("Aggiorna nel Terminale")) { updater.runInTerminal() }
                    .glassProminentButton()
            }
            if let error = updater.terminalError {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Feedback

private struct FeedbackSettings: View {
    @ObservedObject var model: AppModel
    @State private var status: String?
    @State private var showReport = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppInfo.name).font(.title2.weight(.semibold)).fontDesign(.rounded)
                        Text(L("Versione %@", "\(SystemInfo.version) (\(SystemInfo.build))")).foregroundStyle(.secondary)
                        Text(L("Il seguito di quello che scrivi, in ogni app del Mac.")).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                FeedbackButton(symbol: "ladybug", title: L("Segnala un problema"),
                               detail: L("Su GitHub, con versione, macOS e modello del Mac già scritti.")) {
                    Feedback.openIssue(.problem)
                }
                FeedbackButton(symbol: "lightbulb", title: L("Suggerisci un'idea"),
                               detail: L("Un'app dove non funziona, una regola che manca, un modo migliore di suggerire.")) {
                    Feedback.openIssue(.idea)
                }
                FeedbackButton(symbol: "envelope", title: L("Scrivi un'email"),
                               detail: Developer.email) {
                    Feedback.composeEmail()
                }
            } header: {
                Text(L("Feedback"))
            } footer: {
                Footnote(L("GitHub è il canale preferito: le segnalazioni sono pubbliche, quindi non scrivere dati personali né il testo che stavi scrivendo. Per qualcosa di privato usa l'email."))
            }

            Section {
                HStack {
                    Button(L("Copia report")) {
                        Feedback.copyReport(model: model)
                        status = L("Report copiato: incollalo nella segnalazione.")
                    }
                    Button(L("Salva…")) { status = Feedback.saveReport(model: model) }
                    Spacer()
                    Button(showReport ? L("Nascondi") : L("Mostra")) { showReport.toggle() }
                }
                if let status { Footnote(status) }
                if showReport {
                    ScrollView {
                        Text(DiagnosticsReport.make(model: model))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 200)
                }
            } header: {
                Text(L("Diagnostica"))
            } footer: {
                Footnote(L("Il report dice versione, Mac, permessi, stato del motore, le tue scelte e i conteggi di questa sessione. Mai il testo che scrivi, mai nomi di finestre o di file."))
            }

            Section {
                DeveloperLinks()
            }
        }
    }
}

private struct FeedbackButton: View {
    var symbol: String
    var title: String
    var detail: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
    }
}

/// Le parole al massimo nel suggerimento, da 1 (solo la parola in corso) a 20. Il modello si ferma prima se non è sicuro.
struct WordLimitSlider: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(L("Parole al massimo")) {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { Double(prefs.maxWords) }, set: { prefs.maxWords = Int($0.rounded()) }),
                           in: 1...Double(SuggestionLength.maxSlider), step: 1)
                        .frame(width: 180)
                        .accessibilityLabel(L("Parole al massimo"))
                        .accessibilityValue("\(prefs.maxWords)")
                    Text("\(prefs.maxWords)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
            }
            Footnote(prefs.maxWords == 1
                     ? L("Solo la parola che stai scrivendo, mai quella dopo.")
                     : L("Fino a %d parole: il suggerimento si ferma prima se il modello non è sicuro della parola dopo.", prefs.maxWords))
        }
    }
}
