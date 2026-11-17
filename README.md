# Type_w/Me

Il seguito di quello che scrivi, in ogni app del Mac. [English](README.en.md)

Type_w/Me vive nella barra dei menu di macOS. Mentre scrivi in un campo di testo, in qualunque app, dopo una breve
pausa compare in grigio il seguito proposto: Tab lo accetta una parola alla volta, Maiusc-Tab tutto, Esc lo scarta; se
continui a scrivere sparisce da solo. Il modello gira sul Mac (Gemma 3 con llama.cpp, oppure Apple Intelligence):
niente dati che escono, niente account.

L'idea viene da [Cotypist](https://cotypist.app); il codice è nostro, l'app è gratuita e aperta, e l'italiano è la
prima lingua.

## Cosa fa

- **Suggerimenti ovunque.** Nei campi di testo delle app native (Mail, Note, Pages, Messaggi, Safari…) e, dove
  l'app espone il cursore, anche altrove. Parole al massimo a scelta (da 1 a 20) e pausa prima di suggerire
  regolabile.
- **Tasti tuoi.** Accetta una parola, accetta tutto, scarta e riscrivi si cambiano in Impostazioni › Suggerimenti.
- **Gemma 3, il motore consigliato.** Gemma 3 1B con llama.cpp, che sui Mac con Apple silicon è già dentro l'app:
  Homebrew non serve più (su Intel resta `brew install llama.cpp`, oppure Apple Intelligence). Più preciso e più
  veloce del modello di Apple. Al primo uso scarica il modello (circa 0,8 GB); ci sono anche il 4B e il 12B, e puoi
  aggiungere altri modelli GGUF da Hugging Face. Se Ollama è aperto e ha già il modello, si usa quello.
- **Modello sempre pronto.** Gemma parte con l'app e resta caricato (circa 1 GB con il 1B): il primo suggerimento
  dopo una pausa non aspetta l'avvio. Si spegne in Impostazioni › Motori.
- **Apple Intelligence.** Già sul Mac, senza installare niente, ma più debole. Con "Automatico" (il predefinito)
  Type_w/Me usa Gemma quando c'è e Apple Intelligence altrimenti; senza nessuno dei due restano regole e memoria.
- **Il seguito appare mentre arriva.** Il testo grigio compare con le prime parole e si completa man mano.
- **Contesto dallo schermo**, se lo accendi in Impostazioni › App: il modello legge il testo della finestra in cui
  scrivi (la mail a cui rispondi, la pagina che guardi). Lo riconosce il Mac, ogni pochi secondi, e non si salva.
  Serve il permesso Registrazione schermo.
- **Personalizzazione.** Una cronologia di quello che scrivi, cifrata sul Mac, che puoi vedere ed eliminare per app;
  con "Scelta delle parole" i suggerimenti imitano le parole dei tuoi testi nella stessa app. Spenta in partenza.
- **Parole al massimo.** Da 1 a 20; con 1 completa solo la parola che stai scrivendo, mai quella dopo: aiuto all'ortografia.
- **Refusi.** Se la parola che stai scrivendo sembra già sbagliata, niente suggerimento. Si spegne in Impostazioni ›
  Suggerimenti.
- **Modalità batteria.** A batteria (o con Risparmio energia) la pausa si allunga della metà, lo schermo non si legge e il modello
  si spegne dopo i minuti di inattività scelti.
- **Istruzioni tue.** Una frase che vale per tutti i suggerimenti (tono, stile) e, se vuoi, una per app: Mail
  formale, Messaggi da chat, Note sintetico sono i profili consigliati, da accettare con un pulsante.
- **Abbreviazioni.** Una sigla seguita da spazio diventa il testo intero ("cmq" → "comunque", ";firma" → "Cordiali
  saluti, Marta Rossi"). Le scegli tu; nessuna è attiva in partenza.
- **Correzioni italiane in linea.** "perche" diventa "perché", "un pò" diventa "un po'", "qual'è" diventa "qual è",
  maiuscola dopo il punto. Solo parole che sbagliate non vogliono dire niente; le sigle non si toccano.
- **Memoria delle tue frasi.** I seguiti che accetti vengono ricordati sul Mac e riproposti subito, senza modello,
  dalla seconda volta. "Dimentica tutto" li cancella.
- **Riscrivi la selezione.** Ctrl-Opzione-R sul testo selezionato: più breve, più formale, più informale, correggi,
  oppure un'istruzione tua; anteprima e poi "Sostituisci".
- **Completamento a metà riga** (sperimentale): con testo dopo il cursore, il seguito si raccorda a ciò che segue.
- **Appunti come contesto**, se lo scegli: il modello vede l'ultima cosa copiata e la usa se c'entra.
- **App escluse.** Mai nei campi password e con l'input sicuro acceso; gestori di password e Terminale esclusi in
  partenza; dal menu nella barra spegni Type_w/Me nell'app in cui ti trovi.

## Come funziona

Il permesso Accessibilità serve per leggere il campo con il fuoco (testo prima e dopo il cursore, posizione del cursore)
e per vedere i tasti; su alcune versioni di macOS serve anche Monitoraggio input. Il testo fantasma è un pannello
trasparente appoggiato al cursore. A tastiera ferma l'app non fa nulla: il modello lavora solo dopo una pausa mentre
scrivi e si ferma appena riprendi. Quanto pesa lo vedi in Impostazioni › Generale, insieme a parole accettate e tempo
medio di risposta.

Gemma gira in `llama-server` (llama.cpp), incluso nell'app in `Contents/Helpers/llama`: parte con Type_w/Me, solo su
127.0.0.1 e su una porta libera, e resta caricato, così il primo suggerimento è pronto. Si spegne con l'app; a batteria
o con l'interruttore spento in Impostazioni › Motori, dopo i minuti di inattività scelti. Il testo non va mai in rete.
La prima volta llama.cpp scarica il modello da Hugging Face nella sua cache (`~/Library/Caches/llama.cpp`). Su Intel, o
se preferisci, si usa il llama-server di Homebrew o un percorso tuo; Ollama, se è aperto, espone lo stesso endpoint
(`/v1/chat/completions`) e si usa allo stesso modo. Mentre Gemma si avvia risponde Apple Intelligence, se c'è.

Il testo della finestra per il contesto dallo schermo si riconosce con Vision sul Mac e resta in memoria. La cronologia
di scrittura è un file cifrato (AES-GCM) in `~/Library/Application Support/TypeWithMe`, con la chiave nel Portachiavi.
Cosa legge l'app, dove va e cosa salva: [PRIVACY.md](PRIVACY.md).

## Installazione

```sh
brew install --cask gguidotz/tap/typewithme
```

Oppure scarica il DMG dalle [release su GitHub](https://github.com/GGuidotz/typewithme/releases) e trascina l'app in
Applicazioni. Aggiornare: `brew upgrade --cask typewithme`. Disinstallare: `brew uninstall --cask typewithme`
(`--zap` cancella anche preferenze e memoria delle frasi).

L'app non è notarizzata (niente account Apple Developer). Con il cask Homebrew toglie la quarantena da solo. Con il DMG,
al primo avvio macOS la blocca: apri Impostazioni di Sistema › Privacy e sicurezza e premi "Apri comunque".

Permessi, chiesti al primo avvio dalla guida: Accessibilità (leggere il campo e mostrare il suggerimento) e
Monitoraggio input (vedere i tasti); Registrazione schermo solo se accendi il contesto dallo schermo.

Al primo avvio una guida breve spiega i permessi e le scelte. L'app controlla da sola gli aggiornamenti (ogni 6 ore,
si può spegnere) e in Impostazioni › Aggiornamenti mostra le novità e il comando per aggiornare.

### Da Suggeritore

Se usavi Suggeritore, al primo avvio Type_w/Me porta con sé impostazioni, istruzioni, abbreviazioni e memoria delle
frasi. I permessi Accessibilità e Monitoraggio input vanno concessi di nuovo, una volta sola; poi la vecchia app si può
cestinare.

### Compilare dai sorgenti

Servono macOS 26 e gli strumenti a riga di comando (`xcode-select --install`); con Xcode installato si compila anche
l'icona Liquid Glass, se c'è.

```sh
git clone https://github.com/GGuidotz/typewithme.git
cd typewithme
./build.sh              # compila TypeWithMe.app
./build.sh --install    # compila e copia in Applicazioni
./build.sh --dmg        # crea dist/TypeWithMe-<versione>.dmg
```

`packaging/llama.cpp-version` decide la release di llama.cpp inclusa nell'app: `latest` è l'ultima, un tag come `b6500`
la fissa. Una seconda riga facoltativa, `sha256 <hash>`, è l'impronta dell'archivio: se non coincide la build si ferma; se manca,
la build locale avvisa e `--dmg` si ferma. `TYPEWITHME_LLAMA=none ./build.sh` salta llama.cpp (poi serve quello di Homebrew).

## Feedback

Impostazioni › Feedback (o dal menu nella barra › Invia un feedback):

- **Segnala un problema** o **Suggerisci un'idea**: apre una issue su GitHub con versione, macOS e modello del Mac già
  scritti. È il canale preferito; le issue sono pubbliche, quindi niente dati personali né il testo che stavi scrivendo.
- **Scrivi un'email**: a giulioguidotz@yahoo.com, con gli stessi dati in fondo.
- **Diagnostica**: un report da copiare o salvare e allegare. Dice versione, Mac, permessi, stato del motore, le tue
  scelte e i conteggi della sessione; mai il testo che scrivi, mai nomi di finestre o di file.

## Limiti onesti

- Serve macOS 26. Gemma funziona subito su Apple silicon; su Intel serve llama.cpp (o Ollama), oppure un Mac con Apple
  Intelligence attiva. Senza nessuno dei due restano regole, abbreviazioni, correzioni e memoria delle frasi.
- Gemma la prima volta scarica circa 0,8 GB (il 4B circa 2,5 GB, il 12B circa 7 GB) e occupa memoria mentre il
  server è acceso; dopo che si è spento (a batteria, o con l'interruttore spento) il primo suggerimento aspetta qualche
  secondo che riparta.
- Le app Electron (Slack, Teams, VS Code, Notion…) e alcuni browser non sempre dicono dov'è il cursore: lì il
  suggerimento compare in una piccola pillola in basso, o il campo non si legge. Si può escludere l'app.
- I modelli leggono solo la fine del testo, non il documento intero: Gemma gli ultimi duemila caratteri prima del
  cursore, Apple Intelligence gli ultimi settecento. I filtri del modello di Apple possono rifiutare alcuni testi: in
  quel caso non compare niente.
- Le correzioni in linea cancellano e riscrivono la parola appena finita: in qualche app questo passa dalla cronologia
  di Annulla.
- Da Cotypist si riusano il modello già scaricato e le statistiche; le sue memorie sono cifrate e non si importano.
- Un modello base (come quello di Cotypist) continua il testo ma non segue istruzioni: tono per app e riscrittura
  della selezione passano ad Apple Intelligence o a un Gemma istruito.
- L'app non è notarizzata (vedi Installazione). Le versioni pubblicate sono firmate con un'identità locale
  stabile, così macOS ricorda i permessi tra un aggiornamento e l'altro.

## Struttura

| Cartella | Cosa contiene |
|---|---|
| `Sources/Core` | Solo Foundation: contesto e suggerimenti, costruzione dei prompt e pulizia delle risposte, regole italiane, memoria delle frasi, formule fisse, abbreviazioni, catalogo dei modelli, profili per app, esclusioni |
| `Sources/App/Input` | Lettura del campo con Accessibilità, tap della tastiera, inserimento del testo, testo fantasma, lingua |
| `Sources/App/Engines` | I motori dietro il protocollo `CompletionEngine`: Apple Intelligence (FoundationModels), Gemma via HTTP su localhost (llama.cpp o Ollama) e il server `llama-server` come processo figlio |
| `Sources/App` | Avvio AppKit, coordinatore (Completer), riscrittura, barra dei menu, impostazioni (con la scheda Motori), guida, novità, aggiornamenti, Terminale, feedback, diagnostica |
| `Sources/Island` | La vista compatta dello stato, solo SwiftUI e dati semplici: in Impostazioni › Generale e, domani, nell'isola di Cocaine |
| `Resources/Icon` | Icona classica (`tools/render-icon.py`) |
| `Localization` | Italiano (la chiave è il testo) e inglese |
| `tools` | Controllo delle traduzioni e della sintassi, disegno dell'icona, controllo dell'icona compilata |

Pubblicare una versione: aumenta `VERSION`, aggiungi la sezione in `CHANGELOG.md`, poi `./release.sh` (release su
GitHub con il DMG e aggiornamento del cask nel tap).

## Autore

Sviluppato da **gguidotz**: [github.com/GGuidotz/typewithme](https://github.com/GGuidotz/typewithme) ·
giulioguidotz@yahoo.com. Per segnalazioni e idee, meglio le [issue](https://github.com/GGuidotz/typewithme/issues).

## Licenza

MIT. © 2026 GGuidotz.
