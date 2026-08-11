import AppKit
import SwiftUI

/// Shows a full-screen, always-on-top overlay on every connected display
/// when there's an active meeting you haven't joined. Dismissed by
/// clicking "Join" (which also opens the Zoom link) or "Dismiss".
final class AlertWindowController {
    private var windows: [NSWindow] = []
    private var pulseTimer: Timer?

    func show(meeting: CalendarMeeting, onAcknowledged: @escaping () -> Void = {}) {
        // Don't stack duplicate alerts if one's already up.
        guard windows.isEmpty else { return }

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
                meeting: meeting,
                onJoin: { [weak self] in
                    NSWorkspace.shared.open(meeting.joinURL)
                    onAcknowledged()
                    self?.dismiss()
                },
                onDismiss: { [weak self] in
                    onAcknowledged()
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
