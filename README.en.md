# Type_w/Me

What you are about to write, in every Mac app. [Italiano](README.md)

Type_w/Me lives in the macOS menu bar. While you type in a text field, in any app, after a short pause the proposed
continuation appears in grey: Tab accepts it one word at a time, Shift-Tab all of it, Esc dismisses it; keep typing and
it goes away by itself. The model runs on your Mac (Gemma 3 with llama.cpp, or Apple Intelligence): nothing leaves
the Mac, no account.

The idea comes from [Cotypist](https://cotypist.app); the code is ours, the app is free and open, and Italian is the
first language.

## What it does

- **Suggestions everywhere.** In the text fields of native apps (Mail, Notes, Pages, Messages, Safari…) and, where the
  app exposes the cursor, elsewhere too. Maximum words of your choice (1 to 20) and adjustable pause.
- **Your keys.** Accept one word, accept everything, dismiss and rewrite can be changed in Settings › Suggestions.
- **Gemma 3, the recommended engine.** Gemma 3 1B with llama.cpp, which on Apple silicon Macs is already inside the
  app: Homebrew is no longer needed (on Intel, `brew install llama.cpp` remains, or Apple Intelligence). More accurate
  and faster than Apple's model. On first use it downloads the model (about 0.8 GB); 4B and 12B are there too, and you
  can add other GGUF models from Hugging Face. If Ollama is open and already has the model, that is used.
- **Model always ready.** Gemma starts with the app and stays loaded (about 1 GB with the 1B): the first suggestion
  after a pause doesn't wait for startup. You can turn it off in Settings › Engines.
- **Apple Intelligence.** Already on your Mac, nothing to install, but weaker. With "Automatic" (the default)
  Type_w/Me uses Gemma when it's there and Apple Intelligence otherwise; with neither, rules and memory remain.
- **The continuation appears as it arrives.** The grey text shows up with the first words and fills in as it goes.
- **Screen context**, if you turn it on in Settings › Apps: the model reads the text of the window you're typing in
  (the email you're answering, the page you're looking at). The Mac recognizes it every few seconds, and it is never
  saved. It needs the Screen Recording permission.
- **Personalization.** A history of what you write, encrypted on the Mac, that you can view and delete per app; with
  "Word choice" suggestions imitate the words of your own texts in the same app. Off by default.
- **Maximum words.** From 1 to 20; at 1 it completes only the word you are typing, never the next one: spelling help.
- **Typos.** If the word you're typing already looks wrong, no suggestion. Can be turned off in Settings › Suggestions.
- **Battery mode.** On battery (or in Low Power Mode) the pause grows by half, the screen isn't read and the model shuts down
  after the minutes of inactivity you chose.
- **Your instructions.** One sentence for every suggestion (tone, style) and, if you like, one per app: formal Mail,
  chatty Messages, concise Notes are the recommended profiles, accepted with a button.
- **Abbreviations.** An abbreviation followed by a space becomes the full text ("btw" → "by the way", ";sign" →
  "Kind regards, Marta Rossi"). You choose them; none is active by default.
- **Inline Italian corrections.** "perche" becomes "perché", "un pò" becomes "un po'", "qual'è" becomes "qual è",
  capital letter after a period. Only words that mean nothing when misspelled; acronyms are left alone.
- **Memory of your phrases.** The continuations you accept are remembered on the Mac and offered again instantly,
  without the model, from the second time on. "Forget everything" clears them.
- **Rewrite the selection.** Ctrl-Option-R on selected text: shorter, more formal, more casual, fix it, or your own
  instruction; preview, then "Replace".
- **Mid-line completion** (experimental): with text after the cursor, the continuation joins what follows.
- **Clipboard as context**, if you choose so: the model sees the last thing you copied and uses it when relevant.
- **Excluded apps.** Never in password fields or with secure input on; password managers and Terminal excluded by
  default; from the menu bar you can turn Type_w/Me off in the app you're in.

## How it works

The Accessibility permission is needed to read the focused field (text before and after the cursor, cursor position)
and to see keys; on some macOS versions Input Monitoring is needed too. The ghost text is a transparent panel placed at
the cursor. When the keyboard is idle the app does nothing: the model works only after a pause while you type and stops
as soon as you resume. Its footprint is shown in Settings › General, with accepted words and the average response time.

Gemma runs in `llama-server` (llama.cpp), bundled in the app at `Contents/Helpers/llama`: it starts with Type_w/Me,
only on 127.0.0.1 and on a free port, and stays loaded, so the first suggestion is ready. It stops with the app; on
battery or with the switch off in Settings › Engines, after the minutes of inactivity you chose. The text never goes on
the network. The first time llama.cpp downloads the model from Hugging Face into its cache
(`~/Library/Caches/llama.cpp`). On Intel, or if you prefer, the Homebrew llama-server or a path of yours is used;
Ollama, when open, exposes the same endpoint (`/v1/chat/completions`) and is used the same way. While Gemma starts,
Apple Intelligence answers if it's available.

The window text for screen context is recognized with Vision on the Mac and stays in memory. The writing history is an
encrypted file (AES-GCM) in `~/Library/Application Support/TypeWithMe`, with the key in the Keychain. What the app
reads, where it goes and what it saves: [PRIVACY.md](PRIVACY.md).

## Installation

```sh
brew install --cask gguidotz/tap/typewithme
```

Or download the DMG from the [GitHub releases](https://github.com/GGuidotz/typewithme/releases) and drag the app to
Applications. Update: `brew upgrade --cask typewithme`. Uninstall: `brew uninstall --cask typewithme` (`--zap` also
removes preferences and the phrase memory).

The app is not notarized (no Apple Developer account). With the Homebrew cask the quarantine flag is removed for you.
With the DMG, macOS blocks it at first launch: open System Settings › Privacy & Security and press "Open Anyway".

Permissions, asked at first launch by the guide: Accessibility (to read the field and show the suggestion) and Input
Monitoring (to see keys); Screen Recording only if you turn on screen context.

On first launch a short guide explains permissions and choices. The app checks for updates on its own (every 6 hours,
can be turned off) and Settings › Updates shows what's new and the command to update.

### Coming from Suggeritore

If you used Suggeritore, on first launch Type_w/Me brings over settings, instructions, abbreviations and the phrase
memory. The Accessibility and Input Monitoring permissions must be granted again, once; then the old app can be
trashed.

### Build from source

macOS 26 and the command line tools (`xcode-select --install`) are required; with Xcode installed, the Liquid Glass
icon is built too, if present. `--recursive` also fetches Sguardo, the shared design system
(github.com/GGuidotz/sguardo), into `Vendor/Sguardo`; if you already cloned without it, run `git submodule update --init`.

```sh
git clone --recursive https://github.com/GGuidotz/typewithme.git
cd typewithme
./build.sh              # builds TypeWithMe.app
./build.sh --install    # builds and copies to Applications
./build.sh --dmg        # creates dist/TypeWithMe-<version>.dmg
```

`packaging/llama.cpp-version` decides which llama.cpp release is bundled in the app: `latest` is the newest, a tag like
`b6500` pins it. `TYPEWITHME_LLAMA=none ./build.sh` skips llama.cpp (then the Homebrew one is needed).

## Feedback

Settings › Feedback (or menu bar › Send feedback):

- **Report a problem** or **Suggest an idea**: opens a GitHub issue with version, macOS and Mac model already filled
  in. This is the preferred channel; issues are public, so no personal data and not the text you were typing.
- **Write an email**: to giulioguidotz@yahoo.com, with the same details at the bottom.
- **Diagnostics**: a report to copy or save and attach. It lists version, Mac, permissions, engine state, your choices
  and the session's counters; never the text you type, never window or file names.

## Honest limits

- Requires macOS 26. Gemma works out of the box on Apple silicon; on Intel it needs llama.cpp (or Ollama), or a Mac
  with Apple Intelligence on. With neither, rules, abbreviations, corrections and phrase memory remain.
- The first time Gemma downloads about 0.8 GB (4B about 2.5 GB, 12B about 7 GB) and uses memory while the server is
  on; after it has shut down (on battery, or with the switch off) the first suggestion waits a few seconds for it to
  start again.
- Electron apps (Slack, Teams, VS Code, Notion…) and some browsers don't always say where the cursor is: there the
  suggestion shows in a small pill at the bottom, or the field can't be read. The app can be excluded.
- The models read only the end of the text, not the whole document: Gemma the last two thousand characters before the
  cursor, Apple Intelligence the last seven hundred. Apple's filters may refuse some texts: then nothing appears.
- Inline corrections delete and retype the word you just finished: in some apps this goes through Undo history.
- From Cotypist the downloaded model and the statistics are reused; its memories are encrypted and can't be imported.
- A base model (like Cotypist's) continues the text but doesn't follow instructions: per-app tone and rewriting the
  selection fall back to Apple Intelligence or an instruction-tuned Gemma.
- The app is not notarized (see Installation). Released builds are signed with a stable local identity, so
  macOS remembers the permissions across updates.

## Structure

| Folder | Contents |
|---|---|
| `Sources/Core` | Foundation only: context and suggestions, prompt building and answer cleanup, Italian rules, phrase memory, fixed phrases, abbreviations, model catalog, per-app profiles, exclusions |
| `Sources/App/Input` | Reading the field with Accessibility, keyboard tap, text insertion, ghost text, language |
| `Sources/App/Engines` | The engines behind the `CompletionEngine` protocol: Apple Intelligence (FoundationModels), Gemma over HTTP on localhost (llama.cpp or Ollama) and the `llama-server` child process |
| `Sources/App` | AppKit startup, coordinator (Completer), rewrite, menu bar, settings (with the Engines tab), guide, what's new, updates, Terminal, feedback, diagnostics |
| `Sources/Island` | The compact status view, SwiftUI and plain data only: in Settings › General and, later, in Cocaine's island |
| `Resources/Icon` | Classic icon (`tools/render-icon.py`) |
| `Localization` | Italian (the key is the text) and English |
| `tools` | Translation and syntax checks, icon drawing, compiled-icon check |

Publishing a version: bump `VERSION`, add the section to `CHANGELOG.md`, then `./release.sh` (GitHub release with
the DMG and cask update in the tap).

## Author

Developed by **gguidotz**: [github.com/GGuidotz/typewithme](https://github.com/GGuidotz/typewithme) ·
giulioguidotz@yahoo.com. For reports and ideas, the [issues](https://github.com/GGuidotz/typewithme/issues) are best.

## License

MIT. © 2026 GGuidotz.
