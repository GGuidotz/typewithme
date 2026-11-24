// Impostazioni (⌘,): sette schede, con la barra a capsula di Sguardo che galleggia in fondo. Solo ciò che si cambia di
// rado, più aggiornamenti e feedback, come nelle altre app della famiglia. In cima a Generale la vista compatta dello
// stato (Sources/Island); la scheda Motori sta in Sources/App/EngineSettings.swift.

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
        ZStack(alignment: .bottom) {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // La barra delle schede galleggia in fondo: le righe ci scorrono sotto (SGPage lascia lo spazio).
            SettingsTabBar(selection: $model.settingsTab)
                .padding(.bottom, SG.Size.tabBarBottomInset)
        }
        // In alto, sotto i semafori della finestra, il contenuto sfuma invece di tagliarsi di netto.
        .overlay(alignment: .top) { SGProgressiveBlur() }
        .frame(width: Self.size.width, height: Self.size.height)
        // La barra del titolo è trasparente e la vista occupa tutta la finestra: senza questo la zona sicura in alto
        // spinge giù tutto e la barra delle schede finisce sul bordo inferiore.
        .ignoresSafeArea()
        .sguardoAccent(default: .typewithme)
        .id(prefs.language)   // cambio di lingua: ridisegna tutto subito
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
        SGPage {
            SGSection {
                TypeWithMeStatusView(info: completer.statusInfo, labels: .localized, framed: false)
            }

            if let stats = cotypistStats {
                SGSection(L("Da Cotypist")) {
                    SGRowBlock {
                        Text(L("Cotypist ha contato %@ parole accettate in %d giorni.", Format.integer(stats.words), stats.days))
                    }
                    SGDivider()
                    SGRowBlock {
                        Button(prefs.cotypistImported ? L("Già aggiunte al contatore") : L("Aggiungi al contatore di Type_w/Me")) {
                            prefs.acceptedWordsTotal += stats.words
                            prefs.cotypistImported = true
                            diag(.app, "cotypist stats imported")
                        }
                        .buttonStyle(.sgSecondary)
                        .disabled(prefs.cotypistImported)
                    }
                } footer: {
                    SGFootnote(L("Le memorie di Cotypist sono cifrate e non si possono importare. Il suo modello Gemma 3 1B base, se c'è, compare già nel catalogo di Impostazioni › Motori e si usa senza scaricare nulla."))
                }
            }

            SGSection {
                SGToggleRow(L("Suggerimenti attivi"), isOn: Binding(get: { prefs.enabled }, set: { completer.setEnabled($0) }))
                SGDivider()
                SGToggleRow(L("Apri all'accesso"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in
                        loginError = LaunchAtLogin.set(enabled)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                ))
                if let loginError {
                    SGRowBlock { SGFootnote(loginError) }
                }
                SGDivider()
                SGMenuRow(L("Lingua"), selection: $prefs.language,
                          options: AppLanguage.allCases.map { (value: $0, title: $0.title) })
                SGDivider()
                SGAccentRow(L("Colore d'accento"),
                            options: (app: L("Colore dell'app"), system: L("Colore di sistema"), custom: L("Personalizzato")),
                            appDefault: .typewithme)
            } footer: {
                SGFootnote(L("La lingua è quella dell'interfaccia di Type_w/Me. I suggerimenti seguono la lingua in cui stai scrivendo."))
            }

            SGSection(L("Permessi")) {
                SGRowBlock {
                    PermissionRow(title: L("Accessibilità"), granted: accessibility,
                                  detail: L("Per leggere il campo in cui scrivi, mostrare il suggerimento e vedere Tab ed Esc."),
                                  request: { Permissions.requestAccessibility() }, open: { Permissions.openAccessibilitySettings() })
                }
                SGDivider()
                SGRowBlock {
                    PermissionRow(title: L("Monitoraggio input"), granted: inputMonitoring,
                                  detail: L("Su alcune versioni di macOS serve anche questo per vedere i tasti. Se i suggerimenti funzionano, puoi ignorarlo."),
                                  request: { Permissions.requestInputMonitoring() }, open: { Permissions.openInputMonitoringSettings() })
                }
            } footer: {
                SGFootnote(L("Niente esce dal Mac: i permessi servono solo a leggere il campo con il fuoco e a scriverci. Dopo averli concessi, se la voce nella barra resta chiara, riapri Type_w/Me."))
            }
            .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
                accessibility = Permissions.accessibility
                inputMonitoring = Permissions.inputMonitoring
                if accessibility, !completer.monitor.isRunning { completer.startMonitorIfPossible() }
            }

            SGSection {
                SGValueRow(L("Consumo di Type_w/Me")) {
                    Text(usage.map { L("%@ di CPU · %@", Format.percent($0.cpu), Format.bytes($0.memory)) } ?? "–")
                        .lineLimit(1)
                        .fixedSize()
                }
                SGDivider()
                SGRowBlock {
                    Button(L("Rivedi la guida iniziale")) { model.showOnboarding() }
                        .buttonStyle(.sgSecondary)
                }
            } footer: {
                SGFootnote(L("A tastiera ferma l'app non fa nulla. Il modello lavora solo dopo una pausa mentre scrivi, e si ferma appena riprendi."))
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

/// Una riga di permesso: nome, stato scritto e colorato, pulsanti per chiedere o aprire le impostazioni. Senza margini
/// né superficie: li dà chi la contiene (SGRowBlock nelle impostazioni, contentCard nella guida).
struct PermissionRow: View {
    var title: String
    var granted: Bool
    var detail: String
    var request: () -> Void
    var open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Nome e pulsanti sulla stessa riga se c'è posto (le impostazioni), altrimenti i pulsanti sotto (la guida).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    name
                    Spacer(minLength: 8)
                    actions.lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    name
                    HStack(spacing: 8) { actions }
                }
            }
            SGFootnote(detail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(granted ? L("Concesso") : L("Non concesso"))
    }

    private var name: some View {
        Label {
            Text(title).font(SG.Font.body).foregroundStyle(SG.Ink.primary)
        } icon: {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? Palette.calm : Color.orange)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private var actions: some View {
        if granted {
            Text(L("Concesso")).font(SG.Font.body).foregroundStyle(SG.Ink.secondary)
        } else {
            Button(L("Consenti")) { request() }
                .buttonStyle(.sgSecondary)
            Button(L("Apri Impostazioni di Sistema")) { open() }
                .buttonStyle(.sgSecondary)
        }
    }
}

// MARK: - Suggerimenti

private struct SuggestionSettings: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var completer: Completer
    @State private var forgotten = false

    var body: some View {
        SGPage {
            SGSection(L("Tasti")) {
                SGRowBlock {
                    GhostPreview(written: L("Ci vediamo domani alle"), ghost: L(" 10 davanti all'ufficio."),
                                 accept: L("%@ accetta una parola, %@ tutto, %@ scarta.", prefs.acceptWord.display, prefs.acceptAll.display, prefs.dismiss.display),
                                 framed: false)
                }
                SGDivider()
                KeyBindingRecorder(title: L("Accetta una parola"), binding: $prefs.acceptWord, reset: .tab)
                SGDivider()
                KeyBindingRecorder(title: L("Accetta tutto"), binding: $prefs.acceptAll, reset: .shiftTab)
                SGDivider()
                KeyBindingRecorder(title: L("Scarta"), binding: $prefs.dismiss, reset: .escape)
                SGDivider()
                KeyBindingRecorder(title: L("Riscrivi la selezione"), binding: $prefs.rewrite, reset: .controlOptionR)
                SGDivider()
                KeyBindingRecorder(title: L("Correggi il paragrafo"), binding: $prefs.proofread, reset: .controlOptionG)
                SGDivider()
                KeyBindingRecorder(title: L("Sinonimi della selezione"), binding: $prefs.synonyms, reset: .controlOptionS)
            } footer: {
                SGFootnote(L("I tasti di accettazione valgono solo mentre un suggerimento è visibile: senza suggerimento Tab ed Esc fanno quello che fanno sempre. Se continui a scrivere, il suggerimento sparisce da solo."))
            }

            SGSection(L("Quando e quanto")) {
                SGRowBlock { WordLimitSlider(prefs: prefs) }
                SGDivider()
                SGLabeledRow {
                    Text(L("Aspetta prima di suggerire"))
                } trailing: {
                    HStack(spacing: 10) {
                        Slider(value: $prefs.delay, in: 0.05...1.0, step: 0.01)
                            .controlSize(.small)
                            .frame(width: 180)
                            .accessibilityLabel(L("Aspetta prima di suggerire"))
                            .accessibilityValue(L("%d ms", Int(prefs.delay * 1000)))
                        Text(L("%d ms", Int(prefs.delay * 1000)))
                            .font(SG.Font.value)
                            .foregroundStyle(SG.Ink.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(minWidth: 52, alignment: .trailing)
                    }
                }
                SGDivider()
                SGToggleRow(L("Completa anche a metà riga (sperimentale)"), isOn: $prefs.midLine)
                SGDivider()
                SGToggleRow(L("Niente suggerimenti se la parola sembra sbagliata"), isOn: $prefs.hideOnTypo)
                SGDivider()
                SGToggleRow(L("A batteria, risparmia energia"), isOn: $prefs.batterySaver)
            } footer: {
                SGFootnote(L("Il suggerimento arriva dopo una pausa nella scrittura. A metà riga il seguito deve raccordarsi con il testo che c'è dopo il cursore: funziona, ma non sempre bene. Con una parola che sembra sbagliata il suggerimento la allungherebbe con l'errore: meglio niente. A batteria la pausa si allunga della metà, lo schermo non si legge e il modello si spegne dopo i minuti di inattività scelti in Motori."))
            }

            SGSection(L("Correttore")) {
                SGToggleRow(L("Sottolinea gli errori mentre scrivo"), isOn: $prefs.proofreading)
                SGDivider()
                SGToggleRow(L("Controlla anche la grammatica con Apple Intelligence"), isOn: $prefs.grammarCheck)
                    .disabled(!prefs.proofreading)
                if !prefs.learnedWords.isEmpty {
                    SGDivider()
                    SGLabeledRow {
                        Text(L("%@ parole ignorate", Format.integer(prefs.learnedWords.count)))
                            .foregroundStyle(SG.Ink.secondary)
                    } trailing: {
                        Button(L("Segnala di nuovo")) {
                            prefs.learnedWords = []
                            SpellGuard.learned = []
                        }
                        .buttonStyle(.sgSecondary)
                    }
                }
            } footer: {
                SGFootnote(L("Quando ti fermi un attimo il paragrafo si controlla: l'ortografia subito, in italiano e in inglese insieme (i termini inglesi in una frase italiana non sono errori); la grammatica a frase finita, con Apple Intelligence sul Mac. Gli errori si sottolineano (rosso ortografia, blu grammatica); %@ apre le correzioni, Invio le applica. Con del testo selezionato la stessa scorciatoia lo corregge in Riscrivi.", prefs.proofread.display))
            }

            SGSection(L("Correzioni")) {
                SGToggleRow(L("Correzioni italiane in linea"), isOn: $prefs.italianCorrections)
                SGDivider()
                SGToggleRow(L("Maiuscola dopo il punto"), isOn: $prefs.capitalizeSentences)
                    .disabled(!prefs.italianCorrections)
            } footer: {
                SGFootnote(L("Appena finisci la parola: \"perche\" diventa \"perché\", \"un pò\" diventa \"un po'\", \"qual'è\" diventa \"qual è\". Solo parole che sbagliate non vogliono dire niente; le sigle in maiuscolo non si toccano."))
            }

            AbbreviationSection(prefs: prefs)

            SGSection(L("Memoria delle frasi")) {
                SGToggleRow(L("Ricorda le frasi che accetto"), isOn: $prefs.phraseMemory)
                SGDivider()
                SGLabeledRow {
                    Text(L("%@ seguiti ricordati", Format.integer(completer.memory.count)))
                        .foregroundStyle(SG.Ink.secondary)
                } trailing: {
                    Button(L("Dimentica tutto")) {
                        completer.forgetPhrases()
                        forgotten = true
                    }
                    .buttonStyle(.sgSecondary)
                    .disabled(completer.memory.count == 0)
                }
                if forgotten {
                    SGRowBlock { SGFootnote(L("Memoria svuotata.")) }
                }
            } footer: {
                SGFootnote(L("I seguiti che accetti vengono legati alle due parole che li precedono e riproposti subito, senza modello, dalla seconda volta. Restano in un file sul Mac, in Application Support."))
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
        SGSection(L("Abbreviazioni")) {
            ForEach($prefs.abbreviations) { $item in
                SGRowBlock {
                    HStack(spacing: 8) {
                        TextField(text: $item.trigger) { Text(L("Sigla")) }
                            .labelsHidden()
                            .sgField()
                            .frame(width: 130)
                        Image(systemName: "arrow.right").foregroundStyle(SG.Ink.tertiary).accessibilityHidden(true)
                        TextField(text: $item.expansion) { Text(L("Testo intero")) }
                            .labelsHidden()
                            .sgField()
                        Button { removeAbbreviation(item.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(SG.Ink.secondary)
                            .accessibilityLabel(L("Togli l'abbreviazione %@", item.trigger))
                    }
                }
                SGDivider()
            }
            SGRowBlock {
                HStack(spacing: 8) {
                    TextField(text: $newTrigger, prompt: Text(L("Per esempio: ;firma"))) { Text(L("Sigla")) }
                        .labelsHidden()
                        .sgField()
                        .frame(width: 130)
                    Image(systemName: "arrow.right").foregroundStyle(SG.Ink.tertiary).accessibilityHidden(true)
                    TextField(text: $newExpansion, prompt: Text(L("Per esempio: Cordiali saluti, Marta Rossi"))) { Text(L("Testo intero")) }
                        .labelsHidden()
                        .sgField()
                        .onSubmit { addAbbreviation() }
                    Button(L("Aggiungi")) { addAbbreviation() }
                        .buttonStyle(.sgSecondary)
                        .disabled(newAbbreviation == nil)
                }
            }
            if newAbbreviation == nil, let why = abbreviationProblem {
                SGRowBlock { SGFootnote(why) }
            }
        } footer: {
            SGFootnote(L("Scrivi la sigla e poi uno spazio o un segno: diventa il testo intero (\"cmq\" diventa \"comunque\"). Usa sigle che non scriveresti mai per conto tuo, o mettici davanti un punto e virgola (;firma): una parola vera verrebbe sostituita ogni volta. Maiuscole comprese, niente a capo."))
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
        SGPage {
            SGSection(L("Contesto")) {
                SGToggleRow(L("Usa l'app in cui scrivi come contesto"), isOn: $prefs.appContext)
                SGDivider()
                SGToggleRow(L("Usa gli appunti come contesto"), isOn: $prefs.clipboardContext)
                SGDivider()
                SGToggleRow(L("Usa lo schermo come contesto"), isOn: Binding(
                    get: { prefs.screenContext },
                    set: { on in
                        prefs.screenContext = on
                        if on, !ScreenContext.hasPermission { ScreenContext.requestPermission() }
                    }))
                if prefs.screenContext, !ScreenContext.hasPermission {
                    SGDivider()
                    SGLabeledRow {
                        Text(L("Serve il permesso Registrazione schermo.")).foregroundStyle(SG.Ink.secondary)
                    } trailing: {
                        Button(L("Apri Impostazioni di Sistema")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.sgSecondary)
                    }
                }
            } footer: {
                SGFootnote(L("Con l'app il modello legge con Accessibilità il titolo e il testo della finestra in cui scrivi (la mail o la chat a cui rispondi, la pagina), senza il campo in cui scrivi, al più ogni pochi secondi: niente permessi in più. Con gli appunti il modello vede anche l'ultima cosa che hai copiato (nomi, numeri, indirizzi) e la usa se c'entra. Con lo schermo legge il testo della finestra in cui scrivi (una mail a cui rispondi, una pagina), riconosciuto sul Mac, al più ogni pochi secondi e mai a ogni tasto; il testo resta in memoria e non si salva. Spenti, appunti e schermo non vengono letti mai. Dopo aver concesso il permesso può servire riaprire l'app."))
            }

            SGSection(L("App escluse")) {
                ForEach(prefs.excludedApps.sorted(by: { name(for: $0) < name(for: $1) }), id: \.self) { bundleID in
                    SGLabeledRow {
                        HStack(spacing: 8) {
                            Text(name(for: bundleID))
                            Text(bundleID).font(SG.Font.caption).foregroundStyle(SG.Ink.tertiary).lineLimit(1)
                        }
                    } trailing: {
                        Button {
                            prefs.setExcluded(bundleID, false)
                            completer.refreshStatus()
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(SG.Ink.secondary)
                            .accessibilityLabel(L("Togli %@ dalle escluse", name(for: bundleID)))
                    }
                    SGDivider()
                }
                SGRowBlock {
                    HStack(spacing: 8) {
                        SGPickerPill(L("Aggiungi un'app aperta…")) {
                            ForEach(running.filter { !prefs.excludedApps.contains($0.bundleIdentifier ?? "") }, id: \.processIdentifier) { app in
                                Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                                    if let id = app.bundleIdentifier { prefs.setExcluded(id, true); completer.refreshStatus() }
                                }
                            }
                        }
                        .onAppear { refreshRunning() }
                        Spacer(minLength: 8)
                        Button(L("Torna all'elenco di partenza")) { prefs.resetExclusions(); completer.refreshStatus() }
                            .buttonStyle(.sgSecondary)
                    }
                }
            } footer: {
                SGFootnote(L("Qui Type_w/Me non legge e non scrive mai. Nei campi password e con l'input sicuro acceso non lo fa comunque, in nessuna app. Dal menu nella barra puoi spegnere l'app in cui ti trovi."))
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
        SGSection(L("Istruzioni per app")) {
            ForEach(sortedIDs, id: \.self) { bundleID in
                SGRowBlock {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(AppNames.name(for: bundleID))
                            Text(bundleID).font(SG.Font.caption).foregroundStyle(SG.Ink.tertiary).lineLimit(1)
                            Spacer()
                            Button { prefs.appInstructions[bundleID] = nil } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(SG.Ink.secondary)
                                .accessibilityLabel(L("Togli le istruzioni per %@", AppNames.name(for: bundleID)))
                        }
                        TextField(text: binding(for: bundleID), prompt: Text(L("Per esempio: tono formale, frasi complete"))) {
                            Text(AppNames.name(for: bundleID))
                        }
                        .labelsHidden()
                        .sgField()
                    }
                }
                SGDivider()
            }
            SGRowBlock {
                HStack(spacing: 8) {
                    SGPickerPill(L("Aggiungi un'app aperta…")) {
                        ForEach(addable, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                                if let id = app.bundleIdentifier { prefs.appInstructions[id] = "" }
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    if AppProfiles.canAddRecommended(to: prefs.appInstructions) {
                        Button(L("Usa i profili consigliati")) {
                            prefs.appInstructions = AppProfiles.merged(into: prefs.appInstructions)
                        }
                        .buttonStyle(.sgSecondary)
                    }
                }
            }
        } footer: {
            SGFootnote(L("Una frase per il modello che vale solo in quell'app, dopo le tue istruzioni generali. I profili consigliati: Mail formale e cortese, Messaggi informale e breve, Note neutro e sintetico; non sono attivi finché non li accetti. Restano sul Mac."))
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
        SGPage {
            SGSection {
                SGToggleRow(L("Controlla automaticamente (ogni 6 ore)"), isOn: $prefs.autoCheckUpdates)
                SGDivider()
                SGValueRow(L("Versione installata"), value: updater.currentVersion)
                SGDivider()
                SGValueRow(L("Ultimo controllo")) {
                    if let last = updater.lastCheck { Text(last, style: .relative) } else { Text(L("Mai")) }
                }
                SGDivider()
                SGRowBlock {
                    HStack(spacing: 10) {
                        Button(L("Controlla ora")) { Task { await updater.check() } }
                            .buttonStyle(.sgSecondary)
                            .disabled(updater.state == .checking)
                        UpdateStateText(updater: updater)
                    }
                }
            }

            if updater.isUpdateAvailable {
                SGSection { SGRowBlock { UpdateCard(updater: updater) } }
            }

            if let current {
                SGSection(L("Novità di questa versione")) {
                    SGRowBlock { ChangelogList(entries: [current]) }
                    SGDivider()
                    SGRowBlock {
                        Button(L("Mostra la schermata delle novità")) { AppModel.shared.showWhatsNew() }
                            .buttonStyle(.sgSecondary)
                    }
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
            Label(L("Disponibile la versione %@", version), systemImage: "arrow.down.circle.fill").foregroundStyle(.tint)
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
                    .font(SG.Font.bodyEmphasis)
            }
            if !updater.news.isEmpty { ChangelogList(entries: updater.news) }
            Text(L("Per aggiornare, esegui nel Terminale:")).foregroundStyle(SG.Ink.secondary)
            Text(updater.command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SG.Fill.tile, in: RoundedRectangle(cornerRadius: SG.Radius.tile, style: .continuous))
            HStack(spacing: 8) {
                Button(L("Copia comando")) { updater.copyCommand() }
                    .buttonStyle(.sgSecondary)
                Button(L("Aggiorna nel Terminale")) { updater.runInTerminal() }
                    .buttonStyle(.sgPrimary)
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
        SGPage {
            SGSection {
                SGRowBlock {
                    HStack(spacing: 16) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 72, height: 72)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppInfo.name).font(SG.Font.title)
                            Text(L("Versione %@", "\(SystemInfo.version) (\(SystemInfo.build))")).foregroundStyle(SG.Ink.secondary)
                            Text(L("Il seguito di quello che scrivi, in ogni app del Mac.")).foregroundStyle(SG.Ink.secondary)
                        }
                    }
                }
            }

            SGSection(L("Feedback")) {
                FeedbackButton(symbol: "ladybug", title: L("Segnala un problema"),
                               detail: L("Su GitHub, con versione, macOS e modello del Mac già scritti.")) {
                    Feedback.openIssue(.problem)
                }
                SGDivider()
                FeedbackButton(symbol: "lightbulb", title: L("Suggerisci un'idea"),
                               detail: L("Un'app dove non funziona, una regola che manca, un modo migliore di suggerire.")) {
                    Feedback.openIssue(.idea)
                }
                SGDivider()
                FeedbackButton(symbol: "envelope", title: L("Scrivi un'email"),
                               detail: Developer.email) {
                    Feedback.composeEmail()
                }
            } footer: {
                SGFootnote(L("GitHub è il canale preferito: le segnalazioni sono pubbliche, quindi non scrivere dati personali né il testo che stavi scrivendo. Per qualcosa di privato usa l'email."))
            }

            SGSection(L("Diagnostica")) {
                SGRowBlock {
                    HStack(spacing: 8) {
                        Button(L("Copia report")) {
                            Feedback.copyReport(model: model)
                            status = L("Report copiato: incollalo nella segnalazione.")
                        }
                        Button(L("Salva…")) { status = Feedback.saveReport(model: model) }
                        Spacer()
                        Button(showReport ? L("Nascondi") : L("Mostra")) { showReport.toggle() }
                    }
                    .buttonStyle(.sgSecondary)
                }
                if let status {
                    SGRowBlock { SGFootnote(status) }
                }
                if showReport {
                    SGDivider()
                    SGRowBlock {
                        ScrollView {
                            Text(DiagnosticsReport.make(model: model))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 200)
                    }
                }
            } footer: {
                SGFootnote(L("Il report dice versione, Mac, permessi, stato del motore, le tue scelte e i conteggi di questa sessione. Mai il testo che scrivi, mai nomi di finestre o di file."))
            }

            SGSection {
                SGRowBlock { DeveloperLinks() }
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
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(SG.Font.body).foregroundStyle(SG.Ink.primary)
                    Text(detail).font(SG.Font.caption).foregroundStyle(SG.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(SG.Ink.tertiary)
            }
            .padding(.horizontal, SG.Space.rowInset)
            .padding(.vertical, 10)
            .frame(minHeight: SG.Size.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
    }
}

/// Le parole al massimo nel suggerimento, da 1 (solo la parola in corso) a 20. Il modello si ferma prima se non è sicuro.
/// Senza margini né superficie: nelle impostazioni sta in una SGRowBlock, nella guida a pagina.
struct WordLimitSlider: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(L("Parole al massimo")).font(SG.Font.body).foregroundStyle(SG.Ink.primary)
                Spacer(minLength: 8)
                Slider(value: Binding(get: { Double(prefs.maxWords) }, set: { prefs.maxWords = Int($0.rounded()) }),
                       in: 1...Double(SuggestionLength.maxSlider), step: 1)
                    .controlSize(.small)
                    .frame(width: 180)
                    .accessibilityLabel(L("Parole al massimo"))
                    .accessibilityValue("\(prefs.maxWords)")
                Text("\(prefs.maxWords)")
                    .font(SG.Font.value)
                    .foregroundStyle(SG.Ink.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 52, alignment: .trailing)
            }
            SGFootnote(prefs.maxWords == 1
                       ? L("Solo la parola che stai scrivendo, mai quella dopo.")
                       : L("Fino a %d parole: il suggerimento si ferma prima se il modello non è sicuro della parola dopo.", prefs.maxWords))
        }
    }
}
