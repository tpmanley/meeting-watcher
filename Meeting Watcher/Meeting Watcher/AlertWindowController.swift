import AppKit
import SwiftUI

/// Shows a full-screen, always-on-top overlay on every connected display
/// when there's one or more active meetings you haven't joined. Dismissed by
/// clicking "Join" on one of them (which also opens its join link) or
/// "Dismiss All" — either way resolves the whole batch shown, not just the
/// meeting that was clicked.
final class AlertWindowController {
    private var windows: [NSWindow] = []
    private var pulseTimer: Timer?

    func show(meetings: [CalendarMeeting], onResolved: @escaping () -> Void = {}) {
        // Don't stack duplicate alerts if one's already up.
        guard windows.isEmpty, !meetings.isEmpty else { return }

        for screen in NSScreen.screens {
            let window = NSWindow(
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

            let contentView = AlertContentView(
                meetings: meetings,
                onJoin: { [weak self] meeting in
                    NSWorkspace.shared.open(meeting.joinURL)
                    onResolved()
                    self?.dismiss()
                },
                onDismissAll: { [weak self] in
                    onResolved()
                    self?.dismiss()
                }
            )
            window.contentView = NSHostingView(rootView: contentView)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    var isShowing: Bool { !windows.isEmpty }
}
