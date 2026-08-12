# Meeting Watcher

Menu bar app: pulls today's Google Calendar events, and if one has a
Zoom or Knox Meeting link and is currently active but you're not already
on the call, throws up a full-screen "join now" alert.

## Install

```bash
brew tap tpmanley/meeting-watcher https://github.com/tpmanley/meeting-watcher
brew install --cask meeting-watcher
```

`brew upgrade` picks up new versions once the cask is bumped for a new
release.

This is the path for everyone except whoever maintains the Google Cloud
OAuth client the app talks to (see [Distributing via
Homebrew](HOMEBREW.md) for that side). You'll still need to be added as a
test user on that person's OAuth consent screen — first launch → menu bar
icon → **Connect Google Calendar** will otherwise fail with an "access
blocked" error until you are. Testing-mode tokens also need re-consent
roughly every 7 days; that's a Google restriction on unverified apps, not
a bug here.

## Building from source / local development

The sections below are only needed if you're setting up your own Google
Cloud OAuth client (e.g. you're the one distributing this to coworkers)
or working on the code itself.

### 1. Google Cloud setup (one-time, ~5 min)

1. Go to https://console.cloud.google.com/ → create a new project (or
   reuse one).
2. **APIs & Services → Library** → enable **Google Calendar API**.
3. **APIs & Services → Credentials** → **Create Credentials** →
   **OAuth client ID**.
   - Application type: **iOS** (this lets you register a custom URL
     scheme as the redirect, which is what a native Mac app needs —
     macOS app types in the Google console assume a different flow).
   - Bundle ID: anything, e.g. `com.yourname.meetingwatcher`.
4. You'll get a **Client ID** — this native/installed-app flow doesn't
   use a client secret, so you don't need one.
5. Under **OAuth consent screen**, add your own Google account as a
   test user (since this'll stay in "Testing" mode — totally fine for
   personal use, tokens just need re-consent every 7 days unless you
   publish the app, which isn't necessary here).

### 2. Fill in `Secrets.xcconfig`

Copy `Secrets.xcconfig.template` (next to the `.xcodeproj`) to
`Secrets.xcconfig` and fill in your real client ID:

```
GOOGLE_CLIENT_ID = YOUR_CLIENT_ID.apps.googleusercontent.com
```

`Secrets.xcconfig` is gitignored — Xcode substitutes `GOOGLE_CLIENT_ID`
into the `GoogleClientID` key in `Info.plist` at build time, and
`GoogleCalendarService.swift` reads it from there, so the real client ID
never ends up hardcoded in source or committed to git. If the file is
missing, the build fails immediately with a clear error rather than
silently shipping a broken build.

The redirect URI scheme `com.tommanley.meetingwatcher` (in
`GoogleCalendarService.swift` and registered as a custom URL type in
`Info.plist`) doesn't need to change — it isn't sensitive, just an
app-specific callback scheme.

**Distributing a built app to coworkers:** you only need to do this setup
once, on your own machine. Whoever runs `scripts/build-release.sh` bakes
their `Secrets.xcconfig` value into the resulting `.app` — coworkers who
install the built binary (e.g. via the Homebrew cask, see `HOMEBREW.md`)
never need their own Google Cloud project or client ID. They just need to
be added as a test user on your OAuth consent screen.

### 3. Build as a real macOS app (recommended over `swift run`)

A menu-bar-only app (no Dock icon) and custom URL scheme handling both
need an actual `Info.plist` inside an app bundle, which plain
`swift run` won't give you cleanly. Easiest path:

1. Open Xcode → **File → New → Project → macOS → App**.
2. Interface: **AppKit** (or SwiftUI, doesn't matter — we're using
   AppKit APIs directly). Name it `MeetingWatcher`.
3. Delete the auto-generated `AppDelegate.swift` and `main.swift` /
   `App.swift` Xcode creates, and drag in the 7 files from this
   `Sources/` folder instead.
4. In the target's **Info** tab:
   - Add a **URL Type**: identifier `com.yourname.meetingwatcher`,
     URL Schemes: `com.yourname.meetingwatcher` (must match what
     you put in `redirectURI` above, minus the `:/oauth2redirect`
     part).
   - Add key `LSUIElement` = `YES` (this hides the Dock icon —
     alternative to calling `setActivationPolicy(.accessory)` in code,
     doing both is harmless).
5. Build & run (⌘R). You should get a menu bar icon (a little video
   camera). Click it → **Connect Google Calendar** → browser opens →
   consent → done.

### 4. Grant permissions

- First time the alert window tries to appear, macOS may prompt for
  screen-related permissions depending on your OS version — allow it.
- No Accessibility or Screen Recording permission is needed for the
  `CptHost` process check (`pgrep` just reads the process list).

### 5. Install to /Applications (optional)

Running from Xcode (⌘R) launches a copy out of DerivedData, which gets
wiped/rebuilt on every run — fine for development, but not something
you want "Launch at Login" pointed at long-term. To install a stable
copy:

1. In Xcode, **Product → Show Build Folder in Finder**. This opens
   DerivedData at the built product, e.g.
   `.../Build/Products/Debug/Meeting Watcher.app`.
2. Quit any running copy of the app first (menu bar icon → **Quit**),
   and stop the Xcode debug session if it's active.
3. Copy (or drag) `Meeting Watcher.app` into `/Applications`.
4. Launch it from `/Applications` (not from Xcode) going forward.

If you have **Launch at Login** turned on, toggle it off and back on
after replacing `/Applications/Meeting Watcher.app` — `SMAppService`
registers against the specific app bundle, so it can end up pointing at
a stale copy otherwise.

## Debugging / viewing logs

The app logs through `os.Logger` under the subsystem
`com.tommanley.meetingwatcher` — this is the fastest way to see
what it's actually doing (e.g. why a meeting wasn't detected, or why a
notification didn't fire).

View recent history:

```bash
log show --predicate 'subsystem == "com.tommanley.meetingwatcher"' --info --debug --last 6h
```

Watch it live:

```bash
log stream --predicate 'subsystem == "com.tommanley.meetingwatcher"' --level debug
```

Or open **Console.app** and search for `com.tommanley.meetingwatcher`.

What to look for:

- `fetchCalendar` — how many Zoom/Knox Meeting meetings it found for today.
- `skip '<title>': ...` — why a specific calendar event was excluded
  (cancelled, no `dateTime`, no `zoom.us/j/` or `meeting.samsung.net` link
  found, etc).
- `match '<title>': ...` — a meeting it did pick up, with its provider and
  join link.
- `evaluateState` — whether it currently sees an active meeting and
  whether it thinks you're already in a call.
- `Calendar fetch failed: ...` — the calendar couldn't be reached at
  all (expired/revoked OAuth token, network error, etc). This also
  triggers a warning icon in the menu bar and a popup with the same
  message.

The menu itself (click the menu bar icon) also lists today's detected
meetings and the last time the calendar was checked, so you don't
need the logs for a quick sanity check.

## How the detection works

- **"Is there a meeting right now?"** — polls Google Calendar every 5
  minutes for today's events, regex-matches `zoom.us/j/...` or
  `meeting.samsung.net` (Knox Meeting) links out of the
  location/description/hangoutLink fields, and checks if `now` falls
  inside `[start, end]` (with a 60s grace period).
- **"Have I joined it?"** — every 20 seconds, runs
  `pgrep -x CptHost`. That process is Zoom's actual call engine —
  it only exists while you're live in a meeting, unlike the main
  `zoom.us` process which runs anytime the app is open. If it's not
  running and a Zoom meeting is active, you get the full-screen alert.
  There's no equivalent signal for Knox Meeting, so those alerts always
  fire regardless of call state.

## Known limitations / things you may want to extend

- If you have **two Zoom meetings back-to-back** and are in the first
  one when the second starts, this will fire the alert even though
  you're technically "in a call" — it doesn't disambiguate *which*
  meeting you're in, just whether you're in *a* call at all. Fine for
  most people; flag if you want it smarter.
- All-day events and events without a `dateTime` (i.e. no exact time)
  are skipped.
- Google's OAuth consent will need to be re-approved roughly every 7
  days while the app is in "Testing" mode in Cloud Console (a Google
  restriction on unverified apps, not something in this code) — mildly
  annoying, but avoids the app-verification review process for a
  personal tool.
