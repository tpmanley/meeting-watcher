import Foundation

/// Which conferencing tool a meeting's join link points at. `canDetectJoinState`
/// tells `AppDelegate` whether it's worth consulting `ZoomProcessMonitor` at
/// all — that only recognizes Zoom's call process, so for providers where we
/// have no way to tell "have they actually joined?" we just always alert.
enum MeetingProvider: Equatable {
    case zoom
    case knoxMeeting

    var canDetectJoinState: Bool {
        self == .zoom
    }

    var joinButtonLabel: String {
        switch self {
        case .zoom: return "Join Zoom Meeting"
        case .knoxMeeting: return "Join Knox Meeting"
        }
    }
}

struct CalendarMeeting: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let joinURL: URL
    let provider: MeetingProvider
    let isDeclined: Bool

    /// True if "now" falls within [start, end], with a small grace window
    /// so we still alert if the meeting started a minute ago.
    func isActive(at date: Date = Date(), graceSeconds: TimeInterval = 60) -> Bool {
        let effectiveStart = start.addingTimeInterval(-graceSeconds)
        return date >= effectiveStart && date <= end
    }
}

/// Minimal shape of the fields we care about from the Google Calendar
/// events.list response. We don't bother decoding the rest.
struct GCalEventsResponse: Decodable {
    let items: [GCalEvent]
}

struct GCalEvent: Decodable {
    let id: String
    let summary: String?
    let location: String?
    let description: String?
    let hangoutLink: String?
    let conferenceData: GCalConferenceData?
    let start: GCalDateTime
    let end: GCalDateTime
    let status: String?
    let attendees: [GCalAttendee]?

    struct GCalDateTime: Decodable {
        let dateTime: String?
        let date: String? // all-day events use this instead
    }

    /// One attendee's RSVP. `self` marks the entry belonging to the
    /// signed-in account, which is what we check for a decline.
    struct GCalAttendee: Decodable {
        let responseStatus: String?
        let isSelf: Bool?

        private enum CodingKeys: String, CodingKey {
            case responseStatus
            case isSelf = "self"
        }
    }

    /// Third-party conferencing (e.g. a Zoom add-on link) is surfaced here,
    /// not in `location`/`description`/`hangoutLink` (that field is Meet-only).
    struct GCalConferenceData: Decodable {
        let entryPoints: [GCalEntryPoint]?
    }

    struct GCalEntryPoint: Decodable {
        let entryPointType: String?
        let uri: String?
    }
}

struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Int
    let refresh_token: String?
    let scope: String?
    let token_type: String?
}

/// Error shape returned by Google's OAuth token endpoint, e.g.
/// {"error": "invalid_grant", "error_description": "Token has been expired or revoked."}
struct OAuthErrorResponse: Decodable {
    let error: String
    let error_description: String?

    var friendlyMessage: String {
        error_description.map { "\(error): \($0)" } ?? error
    }
}

/// Error shape returned by the Google Calendar API, e.g.
/// {"error": {"code": 401, "message": "Invalid Credentials", ...}}
struct GCalErrorResponse: Decodable {
    struct Body: Decodable {
        let code: Int?
        let message: String?
    }
    let error: Body

    var friendlyMessage: String {
        if let code = error.code, let message = error.message {
            return "\(message) (HTTP \(code))"
        }
        return error.message ?? "Unknown Calendar API error"
    }
}
