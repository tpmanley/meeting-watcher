import AppKit
import ServiceManagement
import os

private let logger = Logger(subsystem: "com.tommanley.meetingwatcher", category: "AppDelegate")

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var launchAtLoginItem: NSMenuItem!
    private let calendarService = GoogleCalendarService()
    private let alertController = AlertWindowController()
    private var pollTimer: Timer?

    private var todaysMeetings: [CalendarMeeting] = []
    private var lastCalendarFetch: Date = .distantPast
    private var currentlyAlertingMeetingID: String?
    private var dismissedMeetingIDs: Set<String> = []
    private var calendarErrorMessage: String?
    private var hasAlertedForCurrentCalendarError = false

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // no Dock icon, menu bar only
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        startPolling()
    }

    private static let meetingTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        rebuildMenu()
    }

    private func updateStatusIcon() {
        if calendarErrorMessage != nil {
            let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Meeting Watcher — calendar error")
            statusItem.button?.image = image
            statusItem.button?.contentTintColor = .systemOrange
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "video.circle", accessibilityDescription: "Meeting Watcher")
            statusItem.button?.contentTintColor = nil
        }
    }

    private func rebuildMenu() {
        updateStatusIcon()
        let menu = NSMenu()
        menu.addItem(withTitle: calendarService.isSignedIn ? "Connected to Google Calendar" : "Connect Google Calendar",
                     action: #selector(connectCalendar), keyEquivalent: "")

        if let calendarErrorMessage {
            menu.addItem(withTitle: "⚠️ Calendar error", action: nil, keyEquivalent: "").isEnabled = false
            let detailItem = menu.addItem(withTitle: "  \(calendarErrorMessage)", action: #selector(manualCheck), keyEquivalent: "")
            detailItem.toolTip = calendarErrorMessage
        }
        menu.addItem(.separator())

        menu.addItem(withTitle: "Today's Meetings", action: nil, keyEquivalent: "").isEnabled = false
        if !calendarService.isSignedIn {
            menu.addItem(withTitle: "  Not signed in", action: nil, keyEquivalent: "").isEnabled = false
        } else if todaysMeetings.isEmpty {
            menu.addItem(withTitle: "  None found", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            for meeting in todaysMeetings {
                let start = Self.meetingTimeFormatter.string(from: meeting.start)
                let end = Self.meetingTimeFormatter.string(from: meeting.end)
                var title = "  \(start)–\(end)  \(meeting.title)"
                if meeting.id == currentlyAlertingMeetingID {
                    title += " (alerting)"
                } else if dismissedMeetingIDs.contains(meeting.id) {
                    title += " (dismissed)"
                } else if meeting.isDeclined {
                    title += " (declined)"
                }
                let item = menu.addItem(withTitle: title, action: #selector(openMeetingZoomLink(_:)), keyEquivalent: "")
                item.representedObject = meeting.joinURL
                item.target = self
                if meeting.isDeclined {
                    let attributedTitle = NSMutableAttributedString(string: title)
                    attributedTitle.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                                  range: NSRange(location: 0, length: attributedTitle.length))
                    item.attributedTitle = attributedTitle
                }
            }
        }
        if lastCalendarFetch != .distantPast {
            let lastFetchTitle = "  Last checked: \(Self.meetingTimeFormatter.string(from: lastCalendarFetch))"
            menu.addItem(withTitle: lastFetchTitle, action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(.separator())

        menu.addItem(withTitle: "Check Now", action: #selector(manualCheck), keyEquivalent: "r")
        menu.addItem(.separator())
        launchAtLoginItem = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func openMeetingZoomLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func connectCalendar() {
        calendarService.signIn { [weak self] result in
            switch result {
            case .success:
                self?.rebuildMenu()
                self?.fetchCalendar()
            case .failure(let error):
                logger.error("Sign-in failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    @objc private func manualCheck() {
        fetchCalendar()
        evaluateState()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            logger.error("Failed to toggle launch at login: \(String(describing: error), privacy: .public)")
        }
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func startPolling() {
        // Refresh calendar data every 5 minutes; check meeting/call state every 20s.
        fetchCalendar()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastCalendarFetch) > 300 {
                self.fetchCalendar()
            }
            self.evaluateState()
        }
    }

    private func fetchCalendar() {
        guard calendarService.isSignedIn else {
            logger.notice("fetchCalendar skipped: not signed in")
            return
        }
        lastCalendarFetch = Date()
        calendarService.fetchTodaysZoomMeetings { [weak self] result in
            switch result {
            case .success(let meetings):
                logger.notice("fetchCalendar: \(meetings.count) zoom meeting(s) today: \(meetings.map { "\($0.title) [\($0.start)–\($0.end)]" }, privacy: .public)")
                self?.todaysMeetings = meetings
                self?.calendarErrorMessage = nil
                self?.hasAlertedForCurrentCalendarError = false
            case .failure(let error):
                let message = error.localizedDescription
                logger.error("Calendar fetch failed: \(message, privacy: .public)")
                self?.calendarErrorMessage = message
                self?.presentCalendarErrorAlertIfNeeded(message)
            }
            self?.rebuildMenu()
        }
    }

    /// Pops a modal alert the moment the calendar stops being reachable,
    /// so the failure isn't just sitting silently in the logs. Only fires
    /// once per outage — it resets when a fetch succeeds again — so a
    /// persistent error (e.g. every 5-minute retry) doesn't spam dialogs.
    private func presentCalendarErrorAlertIfNeeded(_ message: String) {
        guard !hasAlertedForCurrentCalendarError else { return }
        hasAlertedForCurrentCalendarError = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Can't reach Google Calendar"
        alert.informativeText = "\(message)\n\nMeetings won't be detected until this is fixed."
        alert.addButton(withTitle: "Reconnect Google Calendar")
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            connectCalendar()
        }
    }

    private func evaluateState() {
        let now = Date()
        guard let active = todaysMeetings.first(where: { $0.isActive(at: now) && !$0.isDeclined }) else {
            logger.notice("evaluateState: no active meeting among \(self.todaysMeetings.count) cached (now=\(now))")
            let wasAlerting = currentlyAlertingMeetingID != nil
            alertController.dismiss()
            currentlyAlertingMeetingID = nil
            if wasAlerting { rebuildMenu() }
            return
        }

        if active.provider.canDetectJoinState {
            let inMeeting = ZoomProcessMonitor.isInMeeting()
            logger.notice("evaluateState: active meeting '\(active.title)', isInMeeting=\(inMeeting)")

            if inMeeting {
                // You're in a call — assume it's this one and stand down.
                let wasAlerting = currentlyAlertingMeetingID != nil
                alertController.dismiss()
                currentlyAlertingMeetingID = nil
                if wasAlerting { rebuildMenu() }
                return
            }
        } else {
            // No way to tell whether this provider's call is already
            // joined (e.g. Knox Meeting) — always alert until dismissed.
            logger.notice("evaluateState: active meeting '\(active.title)' has no join-state detection; alerting regardless")
        }

        guard !dismissedMeetingIDs.contains(active.id) else {
            return
        }

        // Active meeting, not in a call, not yet dismissed: alert
        // (re-showing is harmless if already showing — show() no-ops when
        // a window is already up).
        let wasAlerting = currentlyAlertingMeetingID == active.id
        currentlyAlertingMeetingID = active.id
        alertController.show(meeting: active) { [weak self] in
            self?.dismissedMeetingIDs.insert(active.id)
            self?.rebuildMenu()
        }
        if !wasAlerting { rebuildMenu() }
    }
}
