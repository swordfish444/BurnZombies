cask "burnzombies" do
  version "0.21.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/swordfish444/BurnZombies/releases/download/v#{version}/BurnZombies-macOS-universal.dmg"
  name "BurnZombies"
  desc "Cleans up orphaned processes, stale worktrees, and rebuildable junk left by AI agents"
  homepage "https://github.com/swordfish444/BurnZombies"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "BurnZombies.app"
  binary "#{appdir}/BurnZombies.app/Contents/MacOS/burnzombies"

  uninstall quit: "io.burnzombies.app"

  zap trash: [
    "~/Library/Application Support/BurnZombies",
    "~/Library/Preferences/io.burnzombies.app.plist",
  ]

  caveats <<~EOS
    BurnZombies runs in your menu bar (look for the flaming skull).
    Want a dry-run preview first? Run before launching:
      burnzombies autopilot look-only
    Run a 10-second read-only check without installing a login item:
      burnzombies audit
  EOS
end
