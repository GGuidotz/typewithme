# Type_w/Me

App macOS per la barra dei menu (Swift/SwiftUI, macOS 26+) che suggerisce il seguito di ciò che scrivi in qualunque
app: testo grigio dopo il cursore, Tab per accettare. Tutto sul Mac. Stesso schema di GGuidotz/whats-going-on e di Nod.

- Nome: visibile Type_w/Me; su disco TypeWithMe (lo slash non può stare nei nomi di file: TypeWithMe.app, eseguibile,
  DMG, cartella in Application Support, cask `typewithme`); bundle id com.gguidotz.typewithme; repository
  GGuidotz/typewithme. Le costanti stanno in `Sources/Core/AppInfo.swift`. Prima l'app si chiamava Suggeritore
  (local.suggeritore.app): la migrazione di preferenze e memoria delle frasi è in `Sources/App/Migration.swift`.
- Compilazione: `./build.sh` (swiftc diretto, niente progetto Xcode). Firma con l'identità locale di Nod
  (~/.nod-signing) se c'è, altrimenti ad hoc: serve perché macOS ricordi i permessi Accessibilità e Monitoraggio input.
  Nel cloud Swift non compila: ogni modifica la prova Giulio sul Mac con `./build.sh --install`. Rileggi il codice con
  cura prima di consegnare. Controlli possibili nel cloud: `python3 -I tools/check-syntax.py` (tree-sitter) e
  `python3 -I tools/check-strings.py`.
- `Sources/Core` non importa SwiftUI né AppKit (solo Foundation): regole, memoria delle frasi, costruzione dei prompt,
  pulizia delle risposte, abbreviazioni, catalogo dei modelli. `Sources/App` è AppKit e SwiftUI; `Sources/App/Input`
  legge il campo (Accessibilità), intercetta i tasti (CGEventTap) e inserisce il testo; `Sources/App/Engines` i motori.
  `Sources/Island` è la vista compatta dello stato (solo SwiftUI e dati semplici, `Type_w/MeStatusInfo`, colori
  suoi): niente Completer né `Palette`, così si riusa nell'isola di Cocaine.
- Motori dietro il protocollo `CompletionEngine` (con `partial` per lo streaming e `contextLimit`): Gemma via HTTP su
  localhost (`LlamaEngine`, endpoint OpenAI `/v1/chat/completions`, sia il nostro `llama-server` gestito da
  `LlamaServer` come processo figlio, sia Ollama su 11434), Apple Intelligence (FoundationModels, `#if canImport`),
  regole e memoria delle frasi. `Completer.activeEngine()` sceglie (Automatico: Gemma, poi Apple, poi regole; mentre
  Gemma si avvia risponde Apple). Mai dati fuori dal Mac: solo 127.0.0.1; la rete serve solo a llama.cpp per
  scaricare il modello.
- Sicurezza: niente in campi password (`AXSecureTextField`), niente con l'input sicuro acceso, lista di app escluse.
  La diagnostica non registra testo scritto, nomi di finestre o di file: solo conteggi e stati.
- Testi: chiave = frase italiana, `L("…")`; ogni chiave nuova va in `Localization/en.lproj/Localizable.strings`.
- Versione: `VERSION` + sezione `## <versione> · <data>` in cima a `CHANGELOG.md` (build.sh la richiede), con la
  versione inglese in `CHANGELOG.en.md`.
- Design: Human Interface Guidelines; minimal; colore mai come unico segnale; cifre tabellari; niente emoji, né
  nell'interfaccia né nei suggerimenti.
- Avvio AppKit (`Sources/App/Main.swift`), NSStatusItem disegnato da noi, impostazioni in una finestra nostra.
  Liquid Glass solo sui controlli che galleggiano (`Sources/App/Style.swift`).
- Leggerezza: a tastiera ferma l'app non fa nulla; una richiesta al modello solo dopo una pausa, annullata se riprendi a
  scrivere; niente letture del campo a ogni tasto oltre a quelle necessarie.
- Repository pubblico: mai dati reali nei testi, negli esempi o nei test (esempi inventati: Marta, Luca, Nexa, Studio Rossi).
- Dalla 0.3.0: llama-server incluso in Contents/Helpers/llama (build.sh, release scelta in packaging/llama.cpp-version),
  contesto dallo schermo (`Sources/App/Input/ScreenContext.swift`, solo in memoria), contesto dall'app via Accessibilità (`Sources/App/Input/WindowText.swift`, fermo per campo per non rompere la cache), cronologia di scrittura cifrata
  (`Sources/App/TypingHistory.swift`, AES-GCM con chiave nel Portachiavi). Per Gemma il testo prima del cursore ha
  l'inizio ancorato (`TextContext.anchored`): non cambiarlo in una finestra che scorre, romperebbe la cache del prompt.
- Dalla 0.5.0: Gemma dentro l'app (`Sources/App/Engines/LlamaRuntime.swift`: `LlamaRuntime` chiama libllama, `LocalGemmaEngine`
  per i modelli base), compilato solo per arm64 con `TWM_INPROCESS_LLAMA` contro gli header in `Vendor/llama` (stessa
  build di `packaging/llama.cpp-version`, `Vendor/llama/TAG`; si aggiornano con `tools/update-llama-headers.sh`).
  `LlamaServer.loadInProcess` lo prova prima di llama-server. Il tap della tastiera gira su un thread suo e decide con
  `TapState` (KeyMonitor.swift); il Completer lo tiene aggiornato con `syncTap()`. I campi WebKit (Mail) si leggono con
  i text marker (`FocusReader.markerField`).
- Dalla 0.5.5: correttore (`Sources/App/Proofreader.swift`: ortografia con NSSpellChecker in it+en, grammatica con
  Apple Intelligence a frase finita, differenze in `Sources/Core/TextDiff.swift`, sottolineature in
  `Sources/App/Input/UnderlineOverlay.swift`), sinonimi (`Sources/App/Synonyms.swift`), soglie per app imparate da
  quello che accetti (`Sources/Core/AppAdaptation.swift`, `ConfidenceStop.strictness`). Scorciatoie nel tap
  (`TapState.proofread`, `TapState.synonyms`).
