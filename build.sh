#!/bin/zsh
# Compila "TypeWithMe.app" (Type_w/Me: lo slash non può stare nei nomi di file) (universale arm64 + x86_64, macOS 26+) con gli strumenti a riga di comando: niente
# progetto Xcode, come What's Going On e Nod.
#   ./build.sh              build/TypeWithMe.app
#   ./build.sh --install    e la copia in /Applications (chiude la copia aperta) e la apre
#   ./build.sh --dmg        e crea dist/TypeWithMe-<versione>.dmg
#   TYPEWITHME_ICON=classic ./build.sh …   usa l'icona classica anche se c'è Xcode
# Firma: con l'identità locale di Nod (~/.nod-signing, ./make-signing-identity.sh in GGuidotz/nod) se c'è, così i
# permessi Accessibilità e Monitoraggio input restano da un aggiornamento all'altro; altrimenti ad hoc (solo prove).
set -euo pipefail
cd "${0:A:h}"

MODE=build
case "${1:-}" in
  --install) MODE=install ;;
  --dmg) MODE=dmg ;;
  "") ;;
  *) echo "uso: ./build.sh [--install|--dmg]" >&2; exit 64 ;;
esac

NAME="TypeWithMe"
EXE=TypeWithMe
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD=build
APP="$BUILD/$NAME.app"
PLIST="$APP/Contents/Info.plist"
plist_set() { /usr/bin/plutil -insert "$1" -string "$2" "$PLIST"; }   # chiave, valore (spazi ammessi)

grep -q "^## $VERSION " CHANGELOG.md || { echo "Manca la sezione '## $VERSION · <data>' in CHANGELOG.md" >&2; exit 1; }

# Traduzioni: ogni L("…") deve avere la sua voce in inglese (avviso, non blocca).
if command -v python3 >/dev/null; then
  python3 -I tools/check-strings.py >/dev/null || echo "Attenzione: traduzioni incomplete (python3 tools/check-strings.py)."
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$PLIST"
cp -R Localization/*.lproj "$APP/Contents/Resources/"
cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"   # Impostazioni › Aggiornamenti › Novità di questa versione
[ -f CHANGELOG.en.md ] && cp CHANGELOG.en.md "$APP/Contents/Resources/CHANGELOG.en.md"   # le stesse, in inglese

# llama-server dentro l'app (Contents/Helpers/llama, con le sue librerie): chi installa non ha bisogno di Homebrew.
# Dalla build di llama.cpp scritta in packaging/llama.cpp-version ("bNNNN"; "latest": l'ultima, risolta adesso), solo per
# Apple silicon; scaricata una volta in build/llama-cache. Senza rete si continua senza: l'app usa quello di Homebrew.
# TYPEWITHME_LLAMA=none ./build.sh … salta questo passo.
LLAMA_TAG=""
if [ "${TYPEWITHME_LLAMA:-}" != none ]; then
  LLAMA_TAG=$(tr -d '[:space:]' < packaging/llama.cpp-version 2>/dev/null || echo latest)
  if [ -z "$LLAMA_TAG" ] || [ "$LLAMA_TAG" = latest ]; then
    # Le release "vX.Y.Z" di llama.cpp non hanno i binari: il file nightly-tag.txt dice la build "bNNNN" che li ha.
    LLAMA_TAG=$(curl -fsSL https://github.com/ggml-org/llama.cpp/releases/latest/download/nightly-tag.txt 2>/dev/null \
      | tr -d '[:space:]') || true
  fi
  LLAMA_CACHE="$BUILD/llama-cache/$LLAMA_TAG"
  if [ -n "$LLAMA_TAG" ] && [ ! -x "$LLAMA_CACHE/llama-server" ]; then
    mkdir -p "$BUILD/llama-cache"
    BASE="https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_TAG/llama-$LLAMA_TAG-bin-macos-arm64"
    ARCHIVE=""
    # Oggi .tar.gz, nelle release più vecchie .zip.
    for ext in tar.gz zip; do
      if curl -fsSL -o "$BUILD/llama-cache/llama.$ext" "$BASE.$ext"; then ARCHIVE="$BUILD/llama-cache/llama.$ext"; break; fi
    done
    if [ -n "$ARCHIVE" ]; then
      UNZIP=$(mktemp -d)
      case "$ARCHIVE" in
        *.zip) unzip -q "$ARCHIVE" -d "$UNZIP" ;;
        *) tar -xzf "$ARCHIVE" -C "$UNZIP" ;;
      esac
      SERVER=$(find "$UNZIP" -type f -name llama-server | head -n 1)
      if [ -n "$SERVER" ]; then
        rm -rf "$LLAMA_CACHE"; mkdir -p "$LLAMA_CACHE"
        cp "$SERVER" "$LLAMA_CACHE/"
        # Le librerie possono stare accanto all'eseguibile o in una cartella lib: tutte nella stessa cartella.
        find "$UNZIP" -name '*.dylib' -exec cp -P {} "$LLAMA_CACHE/" \;
        LICENSE_FILE=$(find "$UNZIP" -maxdepth 3 -name 'LICENSE*' | head -n 1)
        [ -n "$LICENSE_FILE" ] && cp "$LICENSE_FILE" "$LLAMA_CACHE/LICENSE-llama.cpp"
        # Le librerie stanno accanto all'eseguibile: che le cerchi lì anche se la release non lo dice già.
        install_name_tool -add_rpath @loader_path "$LLAMA_CACHE/llama-server" 2>/dev/null || true
      fi
      rm -rf "$UNZIP" "$ARCHIVE"
    fi
  fi
  if [ -n "$LLAMA_TAG" ] && [ -x "$LLAMA_CACHE/llama-server" ]; then
    mkdir -p "$APP/Contents/Helpers/llama"
    # In Helpers solo codice firmato: un file di testo lì fa fallire la firma dell'app. La licenza va in Resources.
    for f in "$LLAMA_CACHE"/*; do
      case "$f" in
        */LICENSE*) cp "$f" "$APP/Contents/Resources/LICENSE-llama.cpp" ;;
        *) cp -P "$f" "$APP/Contents/Helpers/llama/" ;;
      esac
    done
    plist_set SGRLlamaTag "$LLAMA_TAG"
  else
    echo "llama-server non incluso (release di llama.cpp non scaricata): l'app userà quello di Homebrew."
    LLAMA_TAG=""
  fi
fi

SOURCES=(Sources/**/*.swift)
# Apple Intelligence (FoundationModels): collegato "debole", così l'app parte anche su un Mac dove il framework manca
# (il codice controlla comunque la disponibilità prima di usarlo).
LINK=()
SDK=$(xcrun --show-sdk-path 2>/dev/null || true)
if [ -n "$SDK" ] && [ -d "$SDK/System/Library/Frameworks/FoundationModels.framework" ]; then
  LINK=(-Xlinker -weak_framework -Xlinker FoundationModels)
fi
# Gemma dentro l'app (Sources/App/Engines/LlamaRuntime.swift): solo su Apple silicon, collegato alla libllama inclusa
# in Contents/Helpers/llama e compilato contro gli header della stessa build (Vendor/llama, tools/update-llama-headers.sh).
# Senza, resta llama-server.
INPROCESS=no
INPROCESS_FLAGS=()
if [ -n "$LLAMA_TAG" ] && [ -f "${LLAMA_CACHE:-}/libllama.dylib" ] && [ -f Vendor/llama/include/llama.h ]; then
  if [ "$(tr -d '[:space:]' < Vendor/llama/TAG 2>/dev/null)" = "$LLAMA_TAG" ]; then
    INPROCESS=yes
    INPROCESS_FLAGS=(-D TWM_INPROCESS_LLAMA -import-objc-header Vendor/llama/TypeWithMeLlama.h -I Vendor/llama/include
                     -L "$LLAMA_CACHE" -lllama -Xlinker -rpath -Xlinker @executable_path/../Helpers/llama)
  else
    echo "Header di llama.cpp di un'altra build: Gemma solo via llama-server (./tools/update-llama-headers.sh)."
  fi
fi
for arch in arm64 x86_64; do
  mkdir -p "$BUILD/$arch"
  EXTRA=()
  [ "$arch" = arm64 ] && EXTRA=("${INPROCESS_FLAGS[@]}")
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos26.0" "${SOURCES[@]}" "${LINK[@]}" "${EXTRA[@]}" \
    -o "$BUILD/$arch/$EXE"
done
lipo -create "$BUILD/arm64/$EXE" "$BUILD/x86_64/$EXE" -output "$APP/Contents/MacOS/$EXE"

ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/Icon/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Resources/Icon/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Icona Liquid Glass (Resources/Icon/Suggeritore.icon, formato Icon Composer): serve actool di Xcode. Poi
# tools/icon-check la disegna come il Dock: se risulta vuota, o uguale all'icona generica, si resta sulla classica.
ICON_TIER=classic
ICON_CHECK=""
if [ "${TYPEWITHME_ICON:-${SUGGERITORE_ICON:-}}" != classic ] && [ -d Resources/Icon/Suggeritore.icon ]; then
  if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # Xcode anche se è selezionato solo CLT
  fi
  ACTOOL=$(xcrun --find actool 2>/dev/null || true)
  if [ -n "$ACTOOL" ]; then
    rm -rf "$BUILD/icon-out"; mkdir -p "$BUILD/icon-out"
    if "$ACTOOL" Resources/Icon/Suggeritore.icon --compile "$BUILD/icon-out" --output-format human-readable-text \
         --notices --warnings --platform macosx --target-device mac --minimum-deployment-target 26.0 \
         --app-icon Suggeritore --include-all-app-icons --development-region en \
         --output-partial-info-plist "$BUILD/icon-partial.plist" >"$BUILD/actool.log" 2>&1 \
       && [ -f "$BUILD/icon-out/Assets.car" ]; then
      ICON_NAME=$(/usr/bin/plutil -extract CFBundleIconName raw "$BUILD/icon-partial.plist" 2>/dev/null || echo Suggeritore)
      cp "$BUILD/icon-out/Assets.car" "$APP/Contents/Resources/"
      plist_set CFBundleIconName "$ICON_NAME"
      ICON_TIER="liquid-glass"
      if swiftc -O -swift-version 5 tools/icon-check/main.swift tools/icon-check/IconMetrics.swift -o "$BUILD/icon-check" \
           >>"$BUILD/actool.log" 2>&1; then
        ICON_CHECK=$("$BUILD/icon-check" "$APP" "$BUILD/icon-out" "$BUILD" 2>>"$BUILD/actool.log") && rc=0 || rc=$?
        if [ "$rc" -eq 1 ]; then
          echo "Icona Liquid Glass vuota ($ICON_CHECK): uso l'icona classica. Anteprime in $BUILD/icon-preview.png."
          rm -f "$APP/Contents/Resources/Assets.car"
          /usr/bin/plutil -remove CFBundleIconName "$PLIST"
          ICON_TIER=classic
        elif [ "$rc" -ne 0 ]; then
          ICON_CHECK="controllo non riuscito: $ICON_CHECK"
        fi
      else
        ICON_CHECK="controllo non compilato (dettagli in $BUILD/actool.log)"
      fi
    else
      echo "Icona Liquid Glass non compilata (dettagli in $BUILD/actool.log): uso l'icona classica."
    fi
  else
    echo "actool non trovato (serve Xcode): icona classica."
  fi
fi

# Dati per la diagnostica e per gli aggiornamenti (Sources/App/Diagnostics.swift, Sources/App/Updater.swift).
plist_set SGRGitCommit "$COMMIT"
plist_set SGRIconTier "$ICON_TIER"
[ -n "$ICON_CHECK" ] && plist_set SGRIconCheck "$ICON_CHECK"
[ "$MODE" = dmg ] || plist_set SGRSourcePath "$PWD"
plutil -lint "$PLIST" >/dev/null
xattr -cr "$APP"
KC="$HOME/.nod-signing/nod-signing.keychain"
# Prima il codice annidato (llama-server e le sue librerie), poi l'app: stessa identità per tutto.
sign() {
  if [ -f "$KC" ]; then codesign --force --keychain "$KC" --sign "Nod Local Signing" "$@"
  else codesign --force --sign - "$@"; fi
}
[ -f "$KC" ] && security unlock-keychain -p nod "$KC"
if [ -d "$APP/Contents/Helpers/llama" ]; then
  for f in "$APP"/Contents/Helpers/llama/*.dylib(N) "$APP/Contents/Helpers/llama/llama-server"; do
    [ -L "$f" ] || sign "$f"
  done
fi
if [ -f "$KC" ]; then
  SIGNING=local
  sign "$APP"
else
  SIGNING=adhoc
  sign "$APP"
  echo "Attenzione: firma ad hoc. A ogni build macOS dimentica Accessibilità e Monitoraggio input (vedi make-signing-identity.sh di Nod)."
fi
codesign --verify --strict "$APP"
echo "Pronto: $APP ($VERSION, build $BUILD_NUMBER, commit $COMMIT, firma $SIGNING, icona $ICON_TIER${ICON_CHECK:+: $ICON_CHECK}, llama.cpp ${LLAMA_TAG:-da Homebrew}, Gemma dentro l'app: $INPROCESS)"

case "$MODE" in
  install)
    /usr/bin/pkill -x "$EXE" 2>/dev/null || true
    /usr/bin/pkill -x Suggeritore 2>/dev/null || true   # la copia con il nome di prima, se è aperta (l'app vecchia non si cancella)
    rm -rf "/Applications/$NAME.app"
    cp -R "$APP" "/Applications/$NAME.app"
    # Il Finder tiene in cache l'icona vecchia: registra di nuovo l'app.
    touch "/Applications/$NAME.app"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -f "/Applications/$NAME.app" 2>/dev/null || true
    open "/Applications/$NAME.app"
    echo "Installato in /Applications e aperto: guarda la barra dei menu." ;;
  dmg)
    mkdir -p dist
    STAGE=$(mktemp -d)
    cp -R "$APP" "$STAGE/$NAME.app"
    ln -s /Applications "$STAGE/Applications"
    DMG="dist/$NAME-$VERSION.dmg"
    rm -f "$DMG"
    hdiutil create -quiet -volname "Type_w-Me $VERSION" -srcfolder "$STAGE" -format UDZO "$DMG"
    rm -rf "$STAGE"
    shasum -a 256 "$DMG"
    echo "DMG: $DMG" ;;
esac
