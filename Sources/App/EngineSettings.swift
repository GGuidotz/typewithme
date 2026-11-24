// Impostazioni › Motori: quale motore usare (Automatico, Gemma, Apple Intelligence, solo regole), lo stato di
// llama.cpp e del suo server, il modello di Gemma (tre pronti più i tuoi), lo stato di Apple Intelligence e le tue
// istruzioni. I controlli sullo stato girano solo mentre la scheda è aperta. Il riquadro per installare llama.cpp
// (LlamaInstallBox) lo usa anche la guida al primo avvio.

import AppKit
import SwiftUI

struct EngineSettings: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var completer: Completer
    @ObservedObject var llama: LlamaServer

    var body: some View {
        SGPage {
            EngineChoiceSection(prefs: prefs, completer: completer)
            GemmaServerSection(prefs: prefs, llama: llama)
            GemmaModelSection(prefs: prefs, llama: llama)
            CustomModelsSection(prefs: prefs)
            AppleIntelligenceSection(completer: completer)
        }
        .onAppear {
            llama.refreshInstalled()
            llama.refreshOllama()
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in llama.refreshInstalled() }
    }
}

// MARK: - Scelta

private struct EngineChoiceSection: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var completer: Completer

    var body: some View {
        SGSection(L("Motore")) {
            SGMenuRow(L("Motore"), selection: $prefs.engine,
                      options: EngineChoice.allCases.map { (value: $0, title: $0.title) })
            SGDivider()
            SGValueRow(L("In uso adesso")) {
                Text(completer.currentEngineName ?? L("Solo regole e memoria"))
            }
            if let notice = completer.engineNotice {
                SGDivider()
                SGRowBlock { SGFootnote(notice) }
            }
        } footer: {
            SGFootnote(L("Consigliato: Automatico. Usa Gemma quando c'è llama.cpp (o Ollama con il modello), altrimenti Apple Intelligence; mentre Gemma si avvia risponde Apple Intelligence. Con \"Solo regole e memoria\" nessun modello viene chiamato: restano correzioni, abbreviazioni, formule fisse e le frasi che hai accettato."))
        }
    }
}

// MARK: - Gemma

private struct GemmaServerSection: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var llama: LlamaServer

    var body: some View {
        SGSection("Gemma (llama.cpp)") {
            SGLabeledRow {
                Text(verbatim: "llama.cpp")
            } trailing: {
                StateLabel(ok: llama.isInstalled, text: !llama.isInstalled ? L("Non installato")
                           : LlamaServer.bundledTag.map { L("Incluso nell'app (%@)", $0) } ?? L("Installato"))
            }
            if !llama.isInstalled {
                SGDivider()
                SGRowBlock { LlamaInstallBox() }
            }
            SGDivider()
            SGLabeledRow {
                Text(L("Server"))
            } trailing: {
                Text(serverText)
                    .foregroundStyle(SG.Ink.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360, alignment: .trailing)
            }
            SGDivider()
            SGRowBlock {
                HStack(spacing: 10) {
                    if llama.state == .stopped || llama.state.isFailed {
                        Button(L("Avvia ora")) { llama.start() }
                            .buttonStyle(.sgSecondary)
                            .disabled(!llama.isInstalled && !llama.ollamaRunning)
                    } else {
                        Button(L("Ferma")) { llama.stop() }
                            .buttonStyle(.sgSecondary)
                    }
                    if llama.state.isBusy { ProgressView().controlSize(.small) }
                }
            }
            SGDivider()
            SGToggleRow(L("Usa Ollama se è aperto"), isOn: $prefs.useOllama)
            SGDivider()
            SGToggleRow(L("Tieni il modello pronto"), isOn: $prefs.keepModelLoaded)
            if !prefs.keepModelLoaded || prefs.batterySaver {
                SGDivider()
                SGLabeledRow {
                    Text(L("Spegni dopo"))
                } trailing: {
                    Stepper(value: $prefs.llamaIdleMinutes, in: 1...120, step: 1) {
                        Text(L("%d minuti senza richieste", Int(prefs.llamaIdleMinutes)))
                            .font(SG.Font.body)
                            .foregroundStyle(SG.Ink.secondary)
                            .monospacedDigit()
                    }
                    .controlSize(.small)
                }
            }
            SGDivider()
            ServerPathField(prefs: prefs)
        } footer: {
            SGFootnote(L("Il server gira solo sul Mac (127.0.0.1). Con \"Tieni il modello pronto\" parte con l'app e resta caricato (circa 1 GB di memoria con Gemma 3 1B), così il primo suggerimento dopo una pausa arriva subito; altrimenti parte alla prima richiesta e si spegne dopo i minuti scelti. La prima volta scarica il modello nella cache di llama.cpp. Se Ollama è aperto e ha già il modello, si usa quello."))
        }
    }

    private var serverText: String {
        var text = llama.state.title
        if llama.state == .ready {
            text += " · " + llama.modelTitle
            if llama.backend == .ollama { text += " · " + L("via Ollama") }
        } else if llama.state == .downloading {
            let size = prefs.selectedModel.sizeHint
            if !size.isEmpty { text += " (" + size + ")" }
        }
        return text
    }
}

/// Il percorso di llama-server scelto a mano: vale quando premi Invio, non a ogni tasto (il server ripartirebbe).
private struct ServerPathField: View {
    @ObservedObject var prefs: Preferences
    @State private var draft = ""

    var body: some View {
        SGLabeledRow {
            Text(L("Percorso di llama-server"))
        } trailing: {
            TextField(text: $draft, prompt: Text(L("Vuoto: lo cerca in /opt/homebrew/bin e /usr/local/bin"))) {
                Text(L("Percorso di llama-server"))
            }
            .labelsHidden()
            .sgField()
            .frame(width: 320)
            .onSubmit { commit() }
        }
        .onAppear { draft = prefs.llamaServerPath ?? "" }
        .onDisappear { commit() }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        if value != prefs.llamaServerPath { prefs.llamaServerPath = value }
    }
}

private struct GemmaModelSection: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var llama: LlamaServer

    var body: some View {
        SGSection(L("Modello di Gemma")) {
            SGMenuRow(L("Modello"), selection: $prefs.selectedModelID,
                      options: ModelCatalog.all(custom: prefs.customModels).map { (value: $0.id, title: title(for: $0)) })
            let entry = prefs.selectedModel
            if entry.isLocalFile {
                SGDivider()
                SGValueRow(L("File")) { Text(L("già sul Mac, nella cartella di Cotypist")) }
            }
            if entry.usesRawCompletion {
                SGDivider()
                SGRowBlock {
                    SGFootnote(L("Modello base: continua il testo così com'è, in modo naturale, ma non segue le istruzioni (tono, per app) e non riscrive la selezione: per quello si usa Apple Intelligence."))
                }
            }
            if let repo = entry.hfRepo {
                SGDivider()
                SGLabeledRow {
                    Text(verbatim: "Hugging Face")
                } trailing: {
                    Text(repo).foregroundStyle(SG.Ink.secondary).textSelection(.enabled)
                }
            }
            if let name = entry.ollamaName {
                SGDivider()
                SGLabeledRow {
                    Text(verbatim: "Ollama")
                } trailing: {
                    HStack(spacing: 10) {
                        Text(name).foregroundStyle(SG.Ink.secondary).textSelection(.enabled)
                        if llama.ollamaRunning {
                            StateLabel(ok: llama.ollamaHas(entry),
                                       text: llama.ollamaHas(entry) ? L("scaricato in Ollama") : L("non c'è in Ollama"))
                        }
                    }
                }
            }
        } footer: {
            SGFootnote(L("Più grande è il modello, più è preciso e più è lento: per i suggerimenti mentre scrivi basta il 1B. Con Ollama il modello va scaricato prima: ollama pull seguito dal nome."))
        }
    }

    private func title(for entry: ModelEntry) -> String {
        entry.isRecommended ? L("%@ (consigliato)", entry.titleWithSize) : entry.titleWithSize
    }
}

/// I modelli aggiunti da te: un nome, un repository Hugging Face (GGUF, per llama.cpp) e/o un nome di Ollama.
private struct CustomModelsSection: View {
    @ObservedObject var prefs: Preferences
    @State private var title = ""
    @State private var repo = ""
    @State private var ollama = ""

    var body: some View {
        SGSection(L("Altri modelli")) {
            ForEach(prefs.customModels) { entry in
                SGLabeledRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                        Text(detail(for: entry)).font(SG.Font.caption).foregroundStyle(SG.Ink.secondary).lineLimit(1)
                    }
                } trailing: {
                    Button { remove(entry) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(SG.Ink.secondary)
                        .accessibilityLabel(L("Togli %@", entry.title))
                }
                SGDivider()
            }
            field(L("Nome"), prompt: L("Per esempio: Gemma 3 1B veloce"), text: $title)
            SGDivider()
            field(L("Repository Hugging Face"), prompt: L("Per esempio: ggml-org/gemma-3-1b-it-GGUF"), text: $repo)
            SGDivider()
            field(L("Nome in Ollama"), prompt: L("Per esempio: gemma3:1b"), text: $ollama)
            SGDivider()
            SGRowBlock {
                HStack {
                    Spacer()
                    Button(L("Aggiungi il modello")) { add() }
                        .buttonStyle(.sgSecondary)
                        .disabled(ModelCatalog.custom(title: title, hfRepo: repo, ollamaName: ollama) == nil)
                }
            }
        } footer: {
            SGFootnote(L("Basta uno dei due: il repository per llama.cpp o il nome per Ollama. Il modello nuovo diventa quello scelto."))
        }
    }

    private func field(_ label: String, prompt: String, text: Binding<String>) -> some View {
        SGLabeledRow {
            Text(label)
        } trailing: {
            TextField(text: text, prompt: Text(prompt)) { Text(label) }
                .labelsHidden()
                .sgField()
                .frame(width: 320)
        }
    }

    private func detail(for entry: ModelEntry) -> String {
        var parts: [String] = []
        if let repo = entry.hfRepo { parts.append(repo) }
        if let name = entry.ollamaName { parts.append("Ollama: " + name) }
        return parts.joined(separator: " · ")
    }

    private func add() {
        guard let entry = ModelCatalog.custom(title: title, hfRepo: repo, ollamaName: ollama) else { return }
        prefs.customModels.append(entry)
        prefs.selectedModelID = entry.id
        title = ""
        repo = ""
        ollama = ""
    }

    private func remove(_ entry: ModelEntry) {
        if prefs.selectedModelID == entry.id { prefs.selectedModelID = ModelCatalog.defaultID }
        prefs.customModels.removeAll { $0.id == entry.id }
    }
}

// MARK: - Apple Intelligence e istruzioni

private struct AppleIntelligenceSection: View {
    @ObservedObject var completer: Completer

    var body: some View {
        SGSection(L("Apple Intelligence")) {
            SGRowBlock {
                AppleStatusLabel(readyText: L("Apple Intelligence è pronta: il modello gira sul Mac, niente rete."))
            }
            if let error = completer.lastError {
                SGDivider()
                SGRowBlock { SGFootnote(L("Ultimo errore del modello: %@", error)) }
            }
        } footer: {
            SGFootnote(L("Già sul Mac, senza installare niente, ma più debole e più lenta di Gemma. Legge solo gli ultimi 700 caratteri prima del cursore."))
        }
    }
}

/// Le tue istruzioni per il modello: stanno nella scheda Personalizzazione.
struct InstructionsSection: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        SGSection(L("Le tue istruzioni")) {
            SGRowBlock {
                TextField(L("Per esempio: tono informale, frasi corte, niente anglicismi"), text: $prefs.instructions, axis: .vertical)
                    .lineLimit(2...5)
                        .sgField(multiline: true)
            }
        } footer: {
            SGFootnote(L("Una frase che vale per tutti i suggerimenti, con qualunque motore. Il modello la legge insieme al testo: tienila corta e concreta. Non scriverci dati personali: restano sul Mac, ma non servono. Per una frase che vale solo in un'app: Impostazioni › App."))
        }
    }
}

// MARK: - Pezzi condivisi

/// Uno stato con simbolo, colore e parole: il colore non è mai l'unico segnale.
struct StateLabel: View {
    var ok: Bool
    var text: String

    var body: some View {
        Label {
            Text(text).font(SG.Font.body).foregroundStyle(SG.Ink.primary)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Palette.calm : Color.orange)
        }
    }
}

/// Lo stato di Apple Intelligence: pronta, o perché no.
struct AppleStatusLabel: View {
    var readyText: String

    var body: some View {
        let reason = AppleEngine.unavailableReason
        Label {
            Text(reason ?? readyText).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: reason == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(reason == nil ? Palette.calm : Color.orange)
        }
        .font(SG.Font.body)
        .foregroundStyle(SG.Ink.primary)
    }
}

/// Come installare llama.cpp: il comando di Homebrew da copiare o da eseguire nel Terminale; se manca Homebrew,
/// dove trovarlo.
struct LlamaInstallBox: View {
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if Homebrew.isInstalled {
                Text(L("Per installare llama.cpp, esegui nel Terminale:")).foregroundStyle(SG.Ink.secondary)
                Text(Homebrew.installLlamaCommand)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SG.Fill.tile, in: RoundedRectangle(cornerRadius: SG.Radius.tile, style: .continuous))
                HStack(spacing: 8) {
                    Button(copied ? L("Copiato") : L("Copia comando")) {
                        Terminal.copy(Homebrew.installLlamaCommand)
                        copied = true
                    }
                    .buttonStyle(.sgSecondary)
                    Button(L("Installa nel Terminale")) {
                        error = Terminal.run(command: Homebrew.installLlamaCommand)
                    }
                    .buttonStyle(.sgPrimary)
                }
                if let error {
                    Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label {
                    Text(L("Homebrew non è installato: serve per installare llama.cpp. Le istruzioni sono su brew.sh, poi torna qui."))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.orange)
                }
                Link(destination: Homebrew.website) { Text(verbatim: "brew.sh") }
            }
        }
        .font(SG.Font.body)
    }
}
