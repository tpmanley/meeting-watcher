import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.tommanley.meetingwatcher", category: "AlertWindowController")

/// Plain `NSWindow` defaults `canBecomeKey`/`canBecomeMain` to `false` for a
/// borderless style mask, which can leave the overlay unable to take key
/// status if something else (a system dialog, another high-level overlay)
/// is contending for focus when it appears — the buttons stop responding to
/// clicks and there's no keyboard escape hatch. Overriding both plus adding
/// an Escape handler here makes the overlay always interactable.
private final class AlertOverlayWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Shows a full-screen, always-on-top overlay on every connected display
/// when there's one or more active meetings you haven't joined. Dismissed by
/// clicking "Join" on one of them (which also opens its join link), "Dismiss
/// All", or Escape — any of those resolves the whole batch shown, not just
/// the meeting that was clicked. As a failsafe against the overlay ever
/// getting stuck unresponsive, the whole batch also auto-hides after
/// `watchdogInterval` — but that path does *not* run `onResolved`, since the
/// meeting was never actually acknowledged: `evaluateState` (still active,
/// still not in `dismissedMeetingIDs`) will just show it again on its next
/// poll.
final class AlertWindowController {
    private var windows: [AlertOverlayWindow] = []
    private var pulseTimer: Timer?
    private var watchdogTimer: Timer?
    private let watchdogInterval: TimeInterval = 15 * 60
    private var currentMeetingIDs: Set<String> = []

    func show(meetings: [CalendarMeeting], onResolved: @escaping () -> Void = {}) {
        guard !meetings.isEmpty else { return }

        // evaluateState calls this every ~20s with the full current
        // alerting set. Re-binding to an identical set would just flicker
        // the overlay for no reason, so only skip when nothing changed —
        // don't skip outright just because a window is already up, or a
        // meeting that goes active mid-alert (and its resolve closure) gets
        // silently dropped.
        let newIDs = Set(meetings.map(\.id))
        guard windows.isEmpty || newIDs != currentMeetingIDs else { return }
        currentMeetingIDs = newIDs

        let resolve: () -> Void = { [weak self] in
            onResolved()
            self?.dismiss()
        }

        if windows.isEmpty {
            for screen in NSScreen.screens {
                let window = AlertOverlayWindow(
                    contentRect: screen.frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false,
                    screen: screen
                )
                window.level = .screenSaver
                window.isOpaque = false
                window.backgroundColor = NSColor.black.withAlphaComponent(0.85)
                window.ignoresMouseEvents = false
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                windows.append(window)
            }
            NSApp.activate(ignoringOtherApps: true)
        }

        for window in windows {
            window.onEscape = resolve
            window.contentView = NSHostingView(rootView: AlertContentView(
                meetings: meetings,
                onJoin: { meeting in
                    if let joinURL = meeting.joinURL {
                        NSWorkspace.shared.open(joinURL)
                    }
                    resolve()
                },
                onDismissAll: resolve
            ))
            window.makeKeyAndOrderFront(nil)
        }

        watchdogTimer?.invalidate()
        let watchdogInterval = self.watchdogInterval
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: watchdogInterval, repeats: false) { [weak self] _ in
            logger.error("watchdog: alert for \(meetings.map(\.title), privacy: .public) still up after \(watchdogInterval)s, force-hiding (not marking as resolved) so it can re-alert")
            self?.dismiss()
        }
    }

    func dismiss() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        currentMeetingIDs = []
    }

    var isShowing: Bool { !windows.isEmpty }
}
