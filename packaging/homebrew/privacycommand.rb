cask "privacycommand" do
  # TEMPLATE — rendered by the shared release workflow
  # (privacykey/gh-workflows macos-sparkle-release.yml): @@VERSION@@,
  # @@SHA256@@ and @@URL@@ are substituted per release and the result is
  # pushed to privacykey/homebrew-tap/Casks/privacycommand.rb. Do not
  # hand-edit version/sha256/url here.
  version "@@VERSION@@"
  sha256 "@@SHA256@@"

  url "@@URL@@"
  name "privacycommand"
  desc "Inspect macOS app bundles for privacy and security findings"
  homepage "https://github.com/privacykey/privacycommand"

  # Sparkle's appcast lives on gh-pages. Linking it here gives Cask
  # users a sanity check that the version they're installing matches
  # what the in-app updater would otherwise pull.
  livecheck do
    url "https://privacykey.github.io/privacycommand/appcast.xml"
    strategy :sparkle
  end

  app "privacycommand.app"

  # We're not sandboxed, so quitting the app is enough — no need for
  # a tighter `quit:` predicate. The in-app Sparkle updater is
  # suppressed for Cask installs by the UpdateController's
  # HomebrewDetector.
  zap trash: [
    "~/Library/Application Support/privacycommand",
    "~/Library/Caches/org.privacykey.privacycommand",
    "~/Library/Preferences/org.privacykey.privacycommand.plist",
    "~/Library/Saved Application State/org.privacykey.privacycommand.savedState",
  ]
end
