# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS menu-bar app ("Meeting Watcher"). It polls the signed-in user's Google Calendar for
today's events, extracts any that contain a `zoom.us/j/...` or `meeting.samsung.net` (Knox
Meeting) link, and — if one is currently active and the user isn't already on the call — throws
up a full-screen "join now" overlay on every display. No Dock icon (`NSApplication.Accessory`
activation policy + `LSUIElement`).

The Xcode project lives at `Meeting Watcher/Meeting Watcher.xcodeproj`; source is under
`Meeting Watcher/Meeting Watcher/`. This directory is not a git repository.

## Build / test / run

All commands must be run from `Meeting Watcher/` (where the `.xcodeproj` is), and the sandbox
around `xcodebuild` needs to be disabled (`dangerouslyDisableSandbox: true`) — it fails on
CoreSimulator/DerivedData IPC otherwise even for macOS-only builds. The only scheme is
`Meeting Watcher`.

```bash
# Build
xcodebuild -project "Meeting Watcher.xcodeproj" -scheme "Meeting Watcher" -configuration Debug build

# Run all tests (Meeting WatcherTests + Meeting WatcherUITests)
xcodebuild -project "Meeting Watcher.xcodeproj" -scheme "Meeting Watcher" test

# Run a single test (Swift Testing syntax, not XCTest)
xcodebuild -project "Meeting Watcher.xcodeproj" -scheme "Meeting Watcher" test \
  -only-testing:"Meeting WatcherTests/Meeting_WatcherTests/example"
```

Tests use the **Swift Testing** framework (`import Testing`, `@Test`, `#expect`), not XCTest —
new tests should follow that style.

There's no separate lint command configured in the project.

### Debugging without rebuilding

The app logs through `os.Logger` under subsystem `com.tommanley.meetingwatcher`. This is the
primary way to see what it's doing at runtime (why a meeting wasn't detected, why an alert didn't
fire, etc.) — check this before assuming a code path is wrong:

```bash
log stream --predicate 'subsystem == "com.tommanley.meetingwatcher"' --level debug
log show --predicate 'subsystem == "com.tommanley.meetingwatcher"' --info --debug --last 6h
```

Key log lines to grep for: `fetchCalendar`, `skip '<title>': ...` (why an event was excluded),
`match '<title>': ...` (an event that was picked up, with its provider and join link),
`evaluateState` (whether an active meeting / an in-progress call was detected), `Calendar fetch
failed: ...`.

## Architecture

Everything is wired together imperatively in `AppDelegate.swift`, which owns two polling loops on
one `Timer` (started in `startPolling()`):

- Every 5 minutes (or on manual "Check Now"): re-fetch today's calendar via
  `GoogleCalendarService.fetchTodaysZoomMeetings`, cache the result in `todaysMeetings`, rebuild
  the status-bar menu.
- Every 20 seconds: `evaluateState()` decides whether to show or dismiss the full-screen alert,
  based on the cached meetings plus a live process check.

Data flow: `GoogleCalendarService` → `[CalendarMeeting]` (see `Models.swift`) → `AppDelegate`
holds the array and derived UI/alert state → `AlertWindowController` / `AlertContentView` render
the overlay.

### GoogleCalendarService.swift

Handles OAuth (installed-app flow via `ASWebAuthenticationSession`, custom URL scheme redirect)
and calls `calendars/primary/events` for `[startOfDay, endOfDay)`. Only the refresh token is
persisted (via `KeychainHelper`); the access token lives in memory and is refreshed on demand in
`ensureValidAccessToken`.

`clientID` is read from the `GoogleClientID` key in `Info.plist` (not hardcoded) — that key is
populated at build time via `$(GOOGLE_CLIENT_ID)`, which comes from `Secrets.xcconfig` (gitignored,
set as the app target's base configuration in both Debug and Release). Copy
`Secrets.xcconfig.template` to `Secrets.xcconfig` and fill in a real client ID before building; a
missing file fails the `xcodebuild` step immediately with a clear "Unable to open base
configuration reference" error rather than producing a broken build silently.

Each raw `GCalEvent` is filtered/transformed into a `CalendarMeeting` in `fetchEvents`'s
`compactMap`:
- Skipped if `status == "cancelled"`, has no `dateTime` (all-day events), or its date strings
  fail to parse.
- The join link is pulled out of `location` / `description` / `hangoutLink` / conference
  `entryPoints` (all concatenated into one `searchText`, since which field holds it depends on how
  the invite was created) by trying `extractZoomURL` first, then `extractKnoxMeetingURL`. Whichever
  matches sets both `joinURL` and `provider` (`MeetingProvider.zoom` / `.knoxMeeting`, in
  `Models.swift`). A meeting with neither link is skipped entirely.
- `isDeclined` is derived from the event's `attendees` array by finding the entry where
  `isSelf == true` and checking `responseStatus == "declined"`.

Adding a new "what counts as a meeting we care about" provider means: a new regex + extractor
function here, a new `MeetingProvider` case in `Models.swift` (with `canDetectJoinState` and
`joinButtonLabel` filled in), and a branch in the `if let ... else if let ...` chain above — not
changes in `AppDelegate`.

### AppDelegate.swift — state machine

`evaluateState()` is the core decision point, run every 20s:
1. Find the first meeting in `todaysMeetings` that `isActive(at: now)` — an `[start - 60s, end]`
   window (see `CalendarMeeting.isActive`) — and is not declined. If none, dismiss any alert.
2. If `active.provider.canDetectJoinState` is true (currently just Zoom) and
   `ZoomProcessMonitor.isInMeeting()` is true, assume the user is in *that* meeting and stand down
   (note: it can't tell *which* call the user is in, just that one is active — see README "Known
   limitations"). Providers with no detection (Knox Meeting) skip this check entirely and always
   proceed to alert.
3. If the meeting's ID is in `dismissedMeetingIDs`, don't re-alert for it this occurrence.
4. Otherwise show the alert and mark it as `currentlyAlertingMeetingID`; the dismiss callback adds
   the ID to `dismissedMeetingIDs` and triggers a menu rebuild.

`rebuildMenu()` always lists every meeting in `todaysMeetings` (even declined ones — shown with a
`(declined)` suffix and struck through via `NSAttributedString(.strikethroughStyle)`), annotating
the currently-alerting or already-dismissed one.

### ZoomProcessMonitor.swift

Detects an in-progress call by checking for the `CptHost` process (`pgrep -x CptHost`) rather than
the main `zoom.us` process (which runs whenever Zoom is open, meeting or not) or window
title/Screen-Recording-gated signals. This is deliberate — don't swap it for a "cheaper" signal
without checking the doc comment's reasoning.

### AlertWindowController.swift / AlertContentView.swift

`AlertWindowController` creates one borderless, `.screenSaver`-level `NSWindow` per connected
`NSScreen` (so the overlay can't be dodged by switching displays), each hosting the SwiftUI
`AlertContentView` via `NSHostingView`. `show()` is a no-op if a window is already up, so
`evaluateState()` can call it every 20s without stacking duplicates.

### Models.swift

Pure data types: `CalendarMeeting` (the app's internal meeting representation) and the raw
`Decodable` shapes for Google's OAuth token and Calendar API responses (`GCalEvent`,
`TokenResponse`, error bodies). Keep API-shape decoding here rather than inline in
`GoogleCalendarService`.

## Gotchas

- A Decodable property literally named `self` (e.g. for the Calendar API attendee field `"self"`)
  cannot be accessed as `$0.self` — that always resolves to Swift's built-in identity accessor,
  not the stored property, and silently produces a type mismatch. Name the property something
  else (e.g. `isSelf`) and map it via an explicit `CodingKeys`.
- `xcodebuild` under the default sandbox fails on CoreSimulator/DerivedData IPC even though this
  is a macOS-only app with no simulator involved — pass `dangerouslyDisableSandbox: true`.
