# frozen_string_literal: true

# Cask di Type_w/Me per il tap GGuidotz/homebrew-tap. Version e sha256 li aggiorna release.sh.
cask "typewithme" do
  version "0.5.5"
  sha256 "1eaec47417e64323b54414253ae319348aa9e3246b3b7af941c47bf91761d2f4"

  url "https://github.com/GGuidotz/typewithme/releases/download/v#{version}/TypeWithMe-#{version}.dmg"
  name "Type_w/Me"
  desc "Menu bar autocomplete for every Mac app, powered by on-device models"
  homepage "https://github.com/GGuidotz/typewithme"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "TypeWithMe.app"

  postflight do
    # Niente account Apple Developer, quindi l'app non è notarizzata: togliere la quarantena evita "Apri comunque".
    system_command "/usr/bin/xattr",
                   args:         ["-dr", "com.apple.quarantine", "#{appdir}/TypeWithMe.app"],
                   must_succeed: false
  end

  uninstall quit: "com.gguidotz.typewithme"

  zap trash: [
    "~/Library/Preferences/com.gguidotz.typewithme.plist",
    "~/Library/Application Support/TypeWithMe",
  ]

  caveats <<~EOS
    Type_w/Me lives in the menu bar. llama.cpp is included in the app (Apple silicon), so Gemma
    needs no Homebrew; on Intel, run `brew install llama.cpp` or use Apple Intelligence.

    Permissions, asked at first launch: Accessibility (to read the field you type in and show the
    suggestion) and Input Monitoring (to see Tab and Esc). Screen Recording is needed only if you
    turn on screen context in Settings. Nothing leaves your Mac.
  EOS
end
