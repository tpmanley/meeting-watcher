cask "meeting-watcher" do
  version "1.6"
  sha256 "cbaf2b8db1eeb8d9bfa565782530a18a077ff8248df9510317c7aa6c732d928f"

  # Update this to wherever the built zip actually lives — a GitHub Release
  # is the easiest option. Run scripts/build-release.sh to produce the zip
  # and its sha256.
  url "https://github.com/tpmanley/meeting-watcher/releases/download/v#{version}/Meeting-Watcher-#{version}.zip"
  name "Meeting Watcher"
  desc "Menu bar alert when a calendar Zoom/Knox Meeting call is live and you haven't joined"
  homepage "https://github.com/tpmanley/meeting-watcher"

  app "Meeting Watcher.app"

  # The app is ad-hoc signed (no paid Apple Developer ID yet), so downloads
  # come through Gatekeeper quarantined. This is the same thing a coworker
  # would otherwise do by hand via System Settings > Privacy & Security >
  # "Open Anyway". Safe here because we control the build in build-release.sh.
  postflight do
    system_command "/usr/bin/xattr",
                    args: ["-d", "com.apple.quarantine", "#{appdir}/Meeting Watcher.app"],
                    sudo: false
  end

  zap trash: [
    "~/Library/Preferences/com.tommanley.Meeting-Watcher.plist",
    "~/Library/Caches/com.tommanley.Meeting-Watcher",
    "~/Library/Saved Application State/com.tommanley.Meeting-Watcher.savedState",
  ]

  caveats <<~EOS
    Meeting Watcher needs its own Google Cloud OAuth consent screen to
    be in "Testing" mode with you added as a test user — ask the app owner
    to add your Google account there before "Connect Google Calendar" will
    work.
  EOS
end
