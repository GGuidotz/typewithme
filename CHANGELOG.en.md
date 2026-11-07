# What's New

English notes, same format as CHANGELOG.md (the Italian one is the reference). The app uses these when its language
is English; versions missing here fall back to the Italian notes.

## 0.5.0 · 2026-11-07

Gemma inside the app, a keyboard that never waits, and Mail.

### New
- **Gemma inside the app.** With a base model already on the Mac (like Cotypist's) Gemma runs inside Type_w/Me, with no server and no HTTP requests: the first piece of a suggestion arrives in 15-50 milliseconds instead of 90-120, and if you type exactly what the model predicted, the next suggestion is already there. Without the llama.cpp libraries, or with an instruction-tuned model, llama-server stays.

### Improvements
- **Keyboard always responsive.** The tap that intercepts Tab and Esc runs on its own thread and decides without waiting for the rest of the app: before, every key in every app waited for Type_w/Me's main thread, and a slow Accessibility read could freeze the whole Mac's keyboard. Accessibility queries now wait half a second at most.
- **The pause follows your rhythm.** A continuation is requested after a little over half your typical interval between keys (60 to 250 ms), never before the chosen pause: not in the middle of a burst of keys, but right away when you stop.
- **Mail, Safari and WebKit apps.** WebKit fields do not give text positions, only "text markers": the field, the text before and after the caret and the caret are now read that way too, and suggestions appear where the field used to be missing. If a field still is not found, diagnostics say what it exposes (role and attributes, never text).
- **Screen context actually arrives.** When Accessibility gave only a scrap of the window, the context stayed frozen for 45 seconds with that scrap, and the text recognised on screen, which arrives a moment later, never reached the prompt. Now it comes in with the next request, and for base models the context in front of the text grows from 500 to 800 characters.
- **Less memory on 8 GB Macs.** There "Keep the model ready" starts off: Gemma stops after the chosen minutes instead of staying in memory. Screen context is re-read at most every 15 seconds in the same window (immediately when you switch window).

## 0.4.0 · 2026-10-29

Longer, more sensible suggestions with the Cotypist model.

### New
- **Learns from you.** A personal model, built on the Mac from the encrypted typing history, knows the words you usually write after the previous one or two. Before each suggestion it is compared with Gemma's most likely words: if one of yours wins, the suggestion starts there. "Word choice" in Settings › Personalization sets its weight; it learns from every new text.
- **Context like a real document.** With Gemma base the context is no longer a header of instructions: in Mail the subject and the message you are replying to, quoted with "> "; in chats the last messages, one per line. Only written text, no menus or buttons, and it stays fixed while you type in the same field.

### Improvements
- **Better length.** A suggestion keeps going while the average per-token probability stays high, instead of multiplying word probabilities: with Italian words split into several pieces it almost always stopped after the first word.
- **Clean prompt for base models.** Gemma base no longer gets English instructions, the clipboard or whole past texts in front of it, which confused it. The prompt only grows at the end and stays in the cache, so answers are faster.
- **No repetition penalty.** It pushed the model away from common words and made suggestions sound unnatural.
- **More apps.** Chrome and Electron apps (Slack, Discord, Notion, VS Code, Obsidian) only build their accessibility tree when someone asks: Type_w/Me now asks when they come to the front, so the caret and text can be read there too. If the system-wide query fails, the field is looked up in the frontmost app.
- **No HTML tags.** The model sometimes went on with `<strong>`, `</p>` or `**`: the suggestion now stops there, unless you are writing HTML or markdown.
- **Per-app diagnostics.** The report shows, app by app, how many suggestions appeared and why none did elsewhere (no field, no text, text after the cursor, no caret, model unsure), and how model answers stop. Counts only.

## 0.3.0 · 2026-10-28

Suggeritore becomes Type_w/Me: faster suggestions, context from the screen, an encrypted typing history that learns your words, and llama.cpp built into the app. Everything stays on the Mac.

### New features
- **Type_w/Me.** The app's new name. On first launch it brings over Suggeritore's settings, instructions, abbreviations and phrase memory; macOS asks again for Accessibility and Input Monitoring, once. You can move the old app to the Trash.
- **llama.cpp included.** On Apple silicon Macs llama-server ships inside the app: Gemma works without Homebrew. Homebrew's, or a path of your own, still works.
- **Context from the screen.** If you turn it on in Settings › Apps, the model reads the text of the window you are writing in (the email you are replying to, the page you are looking at), recognized on your Mac every few seconds and never on every key. The text stays in memory and is never saved. It needs the Screen Recording permission.
- **Personalization.** A new tab: the typing history records what you write, encrypted on your Mac with the key in the Keychain, also where you accept no suggestion (you can turn that off); you can view it and delete it per app. With "Word choice" suggestions use your own texts from the same app to match your words. Off by default.
- **Your instructions with base models too.** With Cotypist's model (a base model) your instructions, per-app instructions, your texts, the screen and the clipboard reach the model as a header of the text to continue: before, it ignored them.
- **Maximum words.** A slider from 1 to 20 instead of the length choice; at 1 it completes only the word you are typing, never the next one: spelling help without suggestions on what to write.
- **Typos.** If the word you are typing already looks misspelled, no suggestion: it would extend the mistake. Turn it off in Settings › Suggestions.
- **Battery mode.** On battery (or in Low Power Mode) the pause grows by half, the screen is not read and the model stops after the chosen idle minutes.
- **Context from the app.** The model reads, through Accessibility, the title and text of the window you are writing in (the email or chat you are replying to, the page) and writes the continuation as a reply in that conversation. No extra permissions, in memory only, on by default; turn it off in Settings › Apps. The context stays fixed for the same field, so the prompt stays in the cache.

### Improvements
- **Faster suggestions.** The text sent to Gemma keeps the same beginning for hundreds of keys and at most 1,200 characters, and llama-server keeps Gemma 3's full cache with a single slot: the already processed prompt is reused instead of redone on every request.
- **Shorter pause.** 120 ms instead of 350: the request is cancelled anyway if you keep typing. If you had the old default, you move to the new one.
- **Model always ready.** Gemma starts with the app and when the Mac wakes up and stays loaded (about 1 GB with the 1B model): the first suggestion after a break does not wait for it to start. Turn it off in Settings › Engines.
- **The next one.** After you accept a suggestion, the following one is requested right away.
- **Timing diagnostics.** The report shows how long reading the field, the first text and the full answer take, how many prompt tokens come from the cache and how many tokens per second; never text.
- **Your instructions** move from Engines to Personalization.
- **Length that adapts.** With the base model the suggestion goes on while the model is sure of the next word and stops at the first uncertain one, within the maximum of the chosen length: no made-up tails and no stops halfway.
- **Grey text everywhere.** The suggestion always appears after the caret, like the text you type, and wraps from the start of the line when it does not fit. Where the field does not tell where the caret is, no more box above the text.
- **No random continuations.** If the model is not sure of the very first word it suggests nothing, and a continuation made only of digits or punctuation is not shown. From the clipboard the base model gets only written text.
- **No stalls after a long suggestion.** After you accept a suggestion, the next one waits until the inserted text is really in the field; an extra Tab right after does not move the caret to another field.

## 0.2.0 · 2026-10-28

Gemma 3 becomes the recommended engine: more accurate, faster suggestions that appear while the model is still writing them. Everything stays on the Mac.

### New features
- **Gemma with llama.cpp.** A new engine: Gemma 3 1B, more accurate and faster than Apple Intelligence. It needs llama.cpp (installed with Homebrew, also from the guide or Settings › Engines); on first use it downloads the model, about 0.8 GB. The server runs only on your Mac, starts when you type and stops by itself after a few idle minutes.
- **Automatic.** The default engine: Gemma when llama.cpp is there, otherwise Apple Intelligence, otherwise rules and memory. While Gemma starts, the others answer, without waiting.
- **Ollama.** If Ollama is open and already has the model (for example gemma3:1b), Suggeritore uses it instead of starting its own server. You can turn this off in Settings › Engines.
- **More models.** Gemma 3 1B, 4B and 12B ready to choose, plus the ones you add with a Hugging Face repository or an Ollama name.
- **Cotypist's model.** If you have Cotypist, its Gemma 3 1B base model shows up in the catalog as recommended and works right away, with nothing to download. Base models continue the text naturally; instruction-tuned ones also follow your instructions and rewrite the selection.
- **Statistics from Cotypist.** In Settings › General you can add the words accepted so far in Cotypist to the counter. Its memories are encrypted and stay its own.
- **Instructions per app.** One sentence for the model that applies only in one app, in Settings › Apps, with three recommended profiles you accept with a button: formal Mail, chatty Messages, concise Notes.
- **Abbreviations.** Type an abbreviation and then a space: it becomes the full text ("btw" becomes "by the way", ";sign" your signature). You choose them in Settings › Suggestions; none is active by default.
- **Status at a glance.** At the top of Settings › General: the state, the engine in use, words accepted today and all time, accepted suggestions and the average response time. The same view will go into Cocaine's island.

### Improvements
- **The continuation appears as it arrives.** The grey text shows up with the first words and fills in as it goes, with Gemma and with Apple Intelligence: the wait feels shorter.
- **Faster Apple Intelligence.** It reads the last 700 characters instead of two thousand, always picks the most likely word and gets shorter instructions: it answers sooner and wanders less.
- **Settings › Engines.** The Apple Intelligence tab becomes Engines: engine choice, llama.cpp and server status (start, stop, minutes before stopping), model, Apple Intelligence and your instructions.
- **First-run guide.** A new step, "The engine": what changes between Gemma and Apple Intelligence and how to install llama.cpp, with the command to copy or run in Terminal.
- **Menu bar.** The status line also names the engine ("Ready · Gemma 3 1B") and says so while Gemma starts or downloads the model.
- **Rewrite the selection with Gemma.** Rewriting uses the same engine as suggestions.
- **Diagnostics.** The report also lists the engine in use, server status, selected model and average response time; never paths or text.

## 0.1.0 · 2026-10-28

First version: what you are about to write, suggested in grey in any Mac app, all on the Mac.

### New features
- **Suggestions everywhere.** While you type in a text field, after a short pause the proposed continuation appears in grey. Tab accepts the next word, Shift-Tab the whole sentence, Esc dismisses it; keep typing and it goes away by itself. Keys and length are in Settings › Suggestions.
- **Apple Intelligence.** The engine is the model on your Mac: no network, nothing leaves the Mac. When it is unavailable, the rules stay.
- **Inline Italian corrections.** Accents and apostrophes fixed as soon as you finish the word ("perche" becomes "perché", "un pò" becomes "un po'"), with a switch.
- **Memory of your phrases.** The continuations you accept are remembered on the Mac and offered again instantly, without the model; one button forgets everything.
- **Rewrite the selection.** Ctrl-Option-R on selected text: shorter, more formal, more casual, fix it, or your own instruction, with a preview before replacing.
- **Mid-line completion.** With text after the cursor, the suggestion joins what follows (experimental, with a switch).
- **Your instructions.** In Settings › Apple Intelligence one sentence that applies to every suggestion, for example the tone you prefer.
- **Excluded apps.** Never in password fields or apps with secure input; password managers and Terminal excluded by default; any app can be switched off from the menu bar.
- **First-run guide, what's new, updates and feedback.** As in the other apps of the family: permissions explained when needed, what's new after each update, update checks from GitHub, reports with your Mac's details already filled in.
