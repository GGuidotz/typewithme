# Privacy

[English](#english)

Type_w/Me lavora sul tuo Mac e non ha server suoi. Nessun account, nessuna telemetria.

## Cosa legge

- **Il campo con il fuoco**, tramite Accessibilità: il testo prima e dopo il cursore e la posizione del cursore, solo
  mentre scrivi. Mai i campi password e mai con l'input sicuro acceso.
- **I tasti**, per Tab, Maiusc-Tab, Esc e per accorgersi che riprendi a scrivere. Non registra quello che premi, a parte
  la cronologia di scrittura se la accendi (vedi sotto).
- **La finestra in cui scrivi**, se "L'app in cui scrivi come contesto" è accesa (lo è in partenza): titolo e testo
  della finestra letti con Accessibilità ogni pochi secondi, solo in memoria. Il campo password non si legge mai.
- **Gli appunti**, solo se scegli "Appunti come contesto".
- **Lo schermo**, solo se accendi il contesto dallo schermo: il testo della finestra in cui scrivi si riconosce sul Mac
  (Vision) ogni pochi secondi e resta in memoria. L'immagine non si salva.

## Dove va

Solo sul Mac. Il modello gira su `127.0.0.1` (llama-server incluso nell'app, Ollama o Apple Intelligence): il testo che
scrivi non va in rete. La rete serve solo per:

- scaricare il modello da Hugging Face, la prima volta;
- scaricare la release di llama.cpp, in fase di compilazione (`./build.sh`);
- controllare gli aggiornamenti: l'app legge `VERSION` e `CHANGELOG` da GitHub, senza mandare altro.

## Cosa si salva

- Le impostazioni, in UserDefaults.
- La memoria delle frasi che accetti, cifrata come la cronologia (AES-GCM, chiave nel Portachiavi), in `~/Library/Application Support/TypeWithMe/phrases.bin`.
- La cronologia di scrittura, solo se la accendi (Impostazioni › Personalizzazione): un file cifrato (AES-GCM) in
  `~/Library/Application Support/TypeWithMe`, con la chiave nel Portachiavi.
- Niente altro. Lo schermo non si salva mai.

## Come cancellare

- **Dimentica tutto** cancella la memoria delle frasi.
- **Elimina** la cronologia di una singola app, oppure **Elimina tutto** per tutta la cronologia (Impostazioni ›
  Personalizzazione).
- Disinstallando con `brew uninstall --zap --cask typewithme` si cancellano anche preferenze e la cartella
  `TypeWithMe` in Application Support.

## Diagnostica

Il report di Impostazioni › Feedback vive solo in memoria e contiene stati e conteggi (versione, Mac, permessi, motore,
scelte, tempi), mai testo, mai nomi di finestre o di file. Si condivide solo se lo copi e lo mandi tu.

---

# English

Type_w/Me works on your Mac and has no servers of its own. No account, no telemetry.

## What it reads

- **The focused field**, through Accessibility: the text before and after the cursor and the cursor position, only while
  you type. Never password fields, and never with secure input on.
- **Keys**, for Tab, Shift-Tab, Esc and to notice when you resume typing. It does not record what you press, apart from
  the writing history if you turn it on (see below).
- **The window you're typing in**, if "The app you are writing in as context" is on (it is by default): the window
  title and text read through Accessibility every few seconds, in memory only. Password fields are never read.
- **The clipboard**, only if you choose "Clipboard as context".
- **The screen**, only if you turn on screen context: the text of the window you're typing in is recognized on the Mac
  (Vision) every few seconds and stays in memory. The image is not saved.

## Where it goes

Only on the Mac. The model runs on `127.0.0.1` (the llama-server bundled in the app, Ollama or Apple Intelligence): the
text you type does not go on the network. The network is used only to:

- download the model from Hugging Face, the first time;
- download the llama.cpp release, at build time (`./build.sh`);
- check for updates: the app reads `VERSION` and `CHANGELOG` from GitHub, sending nothing else.

## What is saved

- Settings, in UserDefaults.
- The memory of the phrases you accept, encrypted like the history (AES-GCM, key in the Keychain), in `~/Library/Application Support/TypeWithMe/phrases.bin`.
- The writing history, only if you turn it on (Settings › Personalization): an encrypted file (AES-GCM) in
  `~/Library/Application Support/TypeWithMe`, with the key in the Keychain.
- Nothing else. The screen is never saved.

## How to delete

- **Forget everything** clears the phrase memory.
- **Delete** the history of a single app, or **Delete all** for the whole history (Settings › Personalization).
- Uninstalling with `brew uninstall --zap --cask typewithme` also removes preferences and the `TypeWithMe` folder in
  Application Support.

## Diagnostics

The report in Settings › Feedback lives only in memory and contains states and counts (version, Mac, permissions,
engine, choices, timings), never text, never window or file names. It is shared only if you copy it and send it yourself.
