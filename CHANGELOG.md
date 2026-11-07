# Novità

Formato: `## <versione> · <data>`, poi `### Novità`, `### Miglioramenti`, `### Correzioni`, una riga `- ` per
cambiamento. L'app mostra la sezione della sua versione in Impostazioni › Aggiornamenti (Sources/App/Changelog.swift).

## 0.5.0 · 2026-11-07

Gemma dentro l'app, una tastiera che non aspetta mai e Mail.

### Novità
- **Gemma dentro l'app.** Con un modello base già sul Mac (come quello di Cotypist) Gemma gira dentro Type_w/Me, senza server né richieste HTTP: il primo pezzo del seguito arriva in 15-50 millisecondi invece di 90-120, e se scrivi proprio quello che il modello aveva previsto il seguito dopo è già pronto. Senza le librerie di llama.cpp, o con un modello istruito, resta llama-server.

### Miglioramenti
- **Tastiera sempre pronta.** Il tap che intercetta Tab ed Esc gira su un thread suo e decide senza aspettare il resto dell'app: prima ogni tasto, in ogni app, attendeva il thread principale di Type_w/Me, e una lettura Accessibilità lenta poteva bloccare la tastiera di tutto il Mac. Le domande Accessibilità aspettano al massimo mezzo secondo.
- **La pausa segue il tuo ritmo.** Un seguito si chiede dopo poco più di metà del tuo intervallo tipico tra due tasti (tra 60 e 250 ms), mai prima della pausa scelta: non a metà di una raffica di tasti, ma subito quando ti fermi.
- **Mail, Safari e le app WebKit.** I campi WebKit non danno le posizioni del testo ma solo dei "segnaposto" (text marker): ora il campo, il testo prima e dopo il cursore e il cursore si leggono anche così, e il suggerimento compare dove prima il campo non si trovava. Se il campo non si trova ancora, la diagnostica dice che cosa espone (ruolo e attributi, mai testo).
- **Il contesto dallo schermo arriva davvero.** Quando l'Accessibilità dava solo un pezzetto della finestra, il contesto restava fermo 45 secondi con quel pezzetto e il testo riconosciuto sullo schermo, che arriva un attimo dopo, non entrava mai nel prompt. Ora entra alla richiesta successiva, e per i modelli base il contesto davanti al testo passa da 500 a 800 caratteri.
- **Meno memoria sui Mac da 8 GB.** Lì "Tieni il modello pronto" parte spento: Gemma si spegne dopo i minuti scelti invece di restare in memoria. Il contesto dallo schermo si rilegge al più ogni 15 secondi nella stessa finestra (subito se cambi finestra).

## 0.4.0 · 2026-10-29

Suggerimenti più lunghi e sensati con il modello di Cotypist.

### Novità
- **Impara da te.** Un modello personale, costruito sul Mac dalla cronologia di scrittura cifrata, conosce le parole che scrivi di solito dopo le una o due precedenti. Prima di ogni suggerimento si confronta con le parole più probabili per Gemma: se una tua vince, il seguito parte da lì. Il peso lo decide "Scelta delle parole" in Impostazioni › Personalizzazione; impara a ogni testo nuovo.
- **Contesto come in un documento vero.** Con Gemma base il contesto non è più un'intestazione di istruzioni: in Mail l'oggetto e il messaggio a cui rispondi, citato con "> "; in chat gli ultimi messaggi, una riga ciascuno. Solo righe di testo scritto, niente menu o pulsanti, e resta fermo mentre scrivi nello stesso campo.

### Miglioramenti
- **Lunghezza decisa meglio.** Il suggerimento va avanti finché la probabilità media per token resta alta, invece di moltiplicare le probabilità delle parole: con le parole italiane spezzate in più pezzi ci si fermava quasi sempre alla prima.
- **Prompt pulito per i modelli base.** Gemma base non riceve più istruzioni in inglese, appunti o testi tuoi interi davanti, che lo confondevano. Il prompt cresce solo in coda e resta nella cache, quindi le risposte sono più rapide.
- **Niente penalità sulle ripetizioni.** Spingeva il modello lontano da "di", "che", "la" e rendeva il seguito innaturale.
- **Più app.** Chrome e le app Electron (Slack, Discord, Notion, VS Code, Obsidian) accendono il loro albero Accessibilità solo se qualcuno lo chiede: Type_w/Me ora lo chiede quando passano in primo piano, così il cursore e il testo si leggono anche lì. Se la domanda a tutto il sistema non risponde, il campo si cerca nell'app in primo piano.
- **Niente tag HTML.** Il modello a volte continuava con `<strong>`, `</p>` o `**`: ora il suggerimento si ferma lì, a meno che tu non stia scrivendo HTML o markdown.
- **Diagnostica per app.** Il report dice, app per app, quanti suggerimenti sono comparsi e perché altrove no (niente campo, niente testo, testo dopo il cursore, niente cursore, modello incerto), e come si fermano le risposte del modello. Solo conteggi.

## 0.3.0 · 2026-10-28

Suggeritore diventa Type_w/Me: suggerimenti più rapidi, contesto dallo schermo, una cronologia di scrittura cifrata che impara le tue parole, e llama.cpp già dentro l'app. Tutto resta sul Mac.

### Novità
- **Type_w/Me.** Il nome nuovo dell'app. Al primo avvio porta con sé le impostazioni, le istruzioni, le abbreviazioni e la memoria delle frasi di Suggeritore; macOS chiede di nuovo i permessi Accessibilità e Monitoraggio input, una volta sola. La vecchia app si può cestinare.
- **llama.cpp incluso.** Sui Mac con Apple silicon llama-server è dentro l'app: Gemma funziona senza Homebrew. Quello di Homebrew, o un percorso tuo, resta possibile.
- **Contesto dallo schermo.** Se lo accendi in Impostazioni › App, il modello legge il testo della finestra in cui scrivi (la mail a cui rispondi, la pagina che stai guardando), riconosciuto sul Mac ogni pochi secondi e mai a ogni tasto. Il testo resta in memoria e non si salva. Serve il permesso Registrazione schermo.
- **Personalizzazione.** Una scheda nuova: la cronologia di scrittura registra quello che scrivi, cifrato sul Mac con la chiave nel Portachiavi, anche dove non accetti suggerimenti (si può spegnere); la vedi e la elimini per app. Con "Scelta delle parole" i suggerimenti usano i tuoi testi della stessa app per imitarne le parole. Spenta in partenza.
- **Le tue istruzioni anche con i modelli base.** Con il modello di Cotypist (un modello base) le istruzioni, quelle per app, i tuoi testi, lo schermo e gli appunti arrivano al modello come intestazione del testo da continuare: prima li ignorava.
- **Parole al massimo.** Uno slider da 1 a 20 al posto della scelta della lunghezza; con 1 completa solo la parola che stai scrivendo, mai quella dopo: aiuto all'ortografia senza suggerimenti su cosa scrivere.
- **Refusi.** Se la parola che stai scrivendo sembra già sbagliata, niente suggerimento: lo allungherebbe con l'errore. Si spegne in Impostazioni › Suggerimenti.
- **Modalità batteria.** A batteria (o con Risparmio energia) la pausa si allunga della metà, lo schermo non si legge e il modello si spegne dopo i minuti di inattività scelti.
- **Contesto dall'app.** Il modello legge con Accessibilità il titolo e il testo della finestra in cui scrivi (la mail o la chat a cui rispondi, la pagina) e scrive il seguito come risposta in quella conversazione. Niente permessi in più, solo in memoria, acceso in partenza; si spegne in Impostazioni › App. Il contesto resta fermo per lo stesso campo, così il prompt resta nella cache.

### Miglioramenti
- **Suggerimenti più rapidi.** Il testo mandato a Gemma ha l'inizio fermo per centinaia di tasti e al massimo 1.200 caratteri, e llama-server tiene la cache intera di Gemma 3 con un solo slot: il prompt già elaborato si riusa invece di rifarlo a ogni richiesta.
- **Pausa più corta.** 120 ms invece di 350: la richiesta si annulla comunque se riprendi a scrivere. Chi aveva il vecchio valore predefinito passa al nuovo.
- **Modello sempre pronto.** Gemma parte con l'app e al risveglio del Mac e resta caricato (circa 1 GB con il modello 1B): il primo suggerimento dopo una pausa non aspetta l'avvio. Si spegne in Impostazioni › Motori.
- **Il seguito dopo.** Accettato un suggerimento, quello successivo si chiede subito.
- **Diagnostica dei tempi.** Il report dice quanto ci mettono lettura del campo, primo testo e risposta completa, quanti token del prompt vengono dalla cache e quanti token al secondo; mai testo.
- **Le tue istruzioni** passano da Motori a Personalizzazione.
- **Lunghezza che si adatta.** Con il modello base il suggerimento continua finché il modello è sicuro della parola dopo e si ferma alla prima incerta, entro il massimo della lunghezza scelta: niente code inventate e niente arresti a metà.
- **Testo grigio ovunque.** Il suggerimento compare sempre dopo il cursore, come il testo che scrivi, e se non ci sta va a capo dall'inizio della riga. Dove il campo non dice dove sta il cursore niente più riquadro sopra il testo.
- **Niente seguiti a caso.** Se il modello non è sicuro già della prima parola non suggerisce niente, e un seguito fatto solo di cifre o punteggiatura non si mostra. Dagli appunti al modello base arriva solo testo scritto.
- **Niente blocchi dopo un suggerimento lungo.** Accettato un suggerimento, il successivo aspetta che il testo inserito sia davvero nel campo; un Tab in più subito dopo non sposta il cursore in un altro campo.

## 0.2.0 · 2026-10-28

Gemma 3 diventa il motore consigliato: suggerimenti più precisi e più rapidi, che compaiono già mentre il modello li scrive. Tutto resta sul Mac.

### Novità
- **Gemma con llama.cpp.** Un nuovo motore: Gemma 3 1B, più preciso e più veloce di Apple Intelligence. Serve llama.cpp (si installa con Homebrew, anche dalla guida o da Impostazioni › Motori); al primo uso scarica il modello, circa 0,8 GB. Il server gira solo sul Mac, parte quando scrivi e si spegne da solo dopo qualche minuto di pausa.
- **Automatico.** Il motore predefinito: Gemma quando c'è llama.cpp, altrimenti Apple Intelligence, altrimenti regole e memoria. Mentre Gemma si avvia rispondono gli altri, senza aspettare.
- **Ollama.** Se Ollama è aperto e ha già il modello (per esempio gemma3:1b), Suggeritore usa quello invece di avviare un server suo. Si spegne in Impostazioni › Motori.
- **Più modelli.** Gemma 3 1B, 4B e 12B pronti da scegliere, più quelli che aggiungi tu con il repository Hugging Face o il nome in Ollama.
- **Il modello di Cotypist.** Se hai Cotypist, il suo Gemma 3 1B base compare nel catalogo come consigliato e si usa subito, senza scaricare nulla. I modelli base continuano il testo in modo naturale; quelli istruiti seguono anche le tue istruzioni e riscrivono la selezione.
- **Statistiche da Cotypist.** In Impostazioni › Generale puoi aggiungere al contatore le parole accettate finora in Cotypist. Le sue memorie sono cifrate e restano sue.
- **Istruzioni per app.** Una frase per il modello che vale solo in un'app, in Impostazioni › App, con tre profili consigliati da accettare con un pulsante: Mail formale, Messaggi da chat, Note sintetico.
- **Abbreviazioni.** Scrivi una sigla e poi uno spazio: diventa il testo intero ("cmq" diventa "comunque", ";firma" la tua firma). Le scegli tu in Impostazioni › Suggerimenti; nessuna è attiva in partenza.
- **Stato a colpo d'occhio.** In cima a Impostazioni › Generale: lo stato, il motore in uso, le parole accettate oggi e da sempre, i suggerimenti accettati e il tempo medio di risposta. La stessa vista andrà nell'isola di Cocaine.

### Miglioramenti
- **Il seguito appare mentre arriva.** Il testo grigio compare con le prime parole e si completa man mano, con Gemma e con Apple Intelligence: l'attesa si sente meno.
- **Apple Intelligence più svelta.** Legge gli ultimi 700 caratteri invece di duemila, sceglie sempre la parola più probabile e riceve istruzioni più corte: risponde prima e divaga meno.
- **Impostazioni › Motori.** La scheda Apple Intelligence diventa Motori: scelta del motore, stato di llama.cpp e del server (avvia, ferma, minuti prima di spegnersi), modello, Apple Intelligence e le tue istruzioni.
- **Guida al primo avvio.** Un passo nuovo, "Il motore": cosa cambia tra Gemma e Apple Intelligence e come installare llama.cpp, con il comando da copiare o da eseguire nel Terminale.
- **Menu nella barra.** La riga di stato dice anche il motore ("Pronto · Gemma 3 1B") e, mentre Gemma si avvia o scarica il modello, lo scrive.
- **Riscrivi la selezione con Gemma.** La riscrittura usa lo stesso motore dei suggerimenti.
- **Diagnostica.** Il report dice anche motore in uso, stato del server, modello scelto e tempo medio di risposta; mai percorsi né testo.

## 0.1.0 · 2026-10-28

Prima versione: il seguito di ciò che scrivi, suggerito in grigio in qualunque app del Mac, tutto sul Mac.

### Novità
- **Suggerimenti ovunque.** Mentre scrivi in un campo di testo, dopo una breve pausa compare in grigio il seguito proposto. Tab accetta la prossima parola, Maiusc-Tab tutta la frase, Esc lo scarta; se continui a scrivere, sparisce da solo. Tasti e lunghezza si cambiano in Impostazioni › Suggerimenti.
- **Apple Intelligence.** Il motore è il modello sul Mac: niente rete, niente dati che escono. Quando non è disponibile restano le regole.
- **Correzioni italiane in linea.** Accenti e apostrofi sistemati appena finisci la parola ("perche" diventa "perché", "un pò" diventa "un po'"), con interruttore.
- **Memoria delle tue frasi.** I seguiti che accetti vengono ricordati sul Mac e riproposti subito, senza modello; un pulsante dimentica tutto.
- **Riscrivi la selezione.** Ctrl-Opzione-R sul testo selezionato: più breve, più formale, più informale, correggi o un'istruzione tua, con anteprima prima di sostituire.
- **Completamento a metà riga.** Con testo dopo il cursore, il suggerimento si raccorda a ciò che segue (sperimentale, con interruttore).
- **Istruzioni tue.** In Impostazioni › Apple Intelligence una frase che vale per tutti i suggerimenti, per esempio il tono che preferisci.
- **App escluse.** Mai nei campi password e nelle app con input sicuro; gestori di password e Terminale esclusi in partenza; ogni app si spegne dal menu nella barra.
- **Guida al primo avvio, novità, aggiornamenti e feedback.** Come nelle altre app della famiglia: permessi spiegati quando servono, novità dopo ogni aggiornamento, controllo degli aggiornamenti da GitHub, segnalazioni con i dati del Mac già scritti.
