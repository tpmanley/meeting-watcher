import Foundation
import os

private let logger = Logger(subsystem: "com.tommanley.meetingwatcher", category: "ZoomProcessMonitor")

/// Detects whether you're currently in an active Zoom call.
///
/// Zoom's main "zoom.us" process runs any time the app is open, whether
/// or not you're in a meeting. The actual call — audio/video engine —
/// runs in a separate helper process, "CptHost", which only exists while
/// you're in a live meeting. Checking for that process is a much more
/// reliable signal than window titles (needs Screen Recording permission)
/// or mic/camera usage (other apps can trigger those too).
enum ZoomProcessMonitor {
    static func isInMeeting() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "CptHost"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // suppress "no matches" noise

        do {
            try task.run()
            task.waitUntilExit()
            let inMeeting = task.terminationStatus == 0
            logger.notice("pgrep -x CptHost exited \(task.terminationStatus) -> inMeeting=\(inMeeting)")
            return inMeeting
        } catch {
            // If pgrep itself fails to launch, fail safe: assume not in a
            // meeting so we still alert rather than go silent.
            logger.error("pgrep failed to launch: \(String(describing: error))")
            return false
        }
    }
}
