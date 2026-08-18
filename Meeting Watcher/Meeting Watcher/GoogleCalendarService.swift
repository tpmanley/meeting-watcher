import Foundation
import AuthenticationServices
import AppKit
import os

private let logger = Logger(subsystem: "com.tommanley.meetingwatcher", category: "GoogleCalendarService")

/// Handles Google OAuth (installed-app flow via ASWebAuthenticationSession)
/// and pulls today's calendar events, extracting any that contain a
/// zoom.us link in the location, description, or hangoutLink field.
final class GoogleCalendarService: NSObject {

    // MARK: - Google Cloud Console OAuth client
    // (type: iOS, so you can register a custom URL scheme as the redirect URI)
    //
    // clientID comes from the GoogleClientID key in Info.plist, which Xcode
    // fills in from the GOOGLE_CLIENT_ID build setting in Secrets.xcconfig
    // (gitignored — see Secrets.xcconfig.template) rather than being
    // hardcoded here, so it's never committed to source control.
    private let clientID: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String,
              !value.isEmpty, !value.hasPrefix("$(") else {
            fatalError("Missing GoogleClientID — copy Secrets.xcconfig.template to Secrets.xcconfig and fill in your Google OAuth client ID")
        }
        return value
    }()
    private let redirectURI = "com.tommanley.meetingwatcher:/oauth2redirect"
    private let scope = "https://www.googleapis.com/auth/calendar.events.readonly"

    private var accessToken: String?
    private var accessTokenExpiry: Date = .distantPast
    private var webAuthSession: ASWebAuthenticationSession?

    // MARK: - Public API

    /// Kicks off the browser-based consent flow. Call once, e.g. from a
    /// "Connect Google Calendar" menu item. Stores the refresh token in
    /// Keychain on success.
    func signIn(completion rawCompletion: @escaping (Result<Void, Error>) -> Void) {
        let completion: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async { rawCompletion(result) }
        }
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent")
        ]

        guard let scheme = URL(string: redirectURI)?.scheme else {
            completion(.failure(NSError(domain: "GoogleCalendarService", code: 1)))
            return
        }

        let session = ASWebAuthenticationSession(
            url: components.url!,
            callbackURLScheme: scheme
        ) { [weak self] callbackURL, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            guard
                let callbackURL,
                let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value
            else {
                completion(.failure(NSError(domain: "GoogleCalendarService", code: 2)))
                return
            }
            self.exchangeCodeForTokens(code: code, completion: completion)
        }
        session.presentationContextProvider = self
        // With this set to false, ASWebAuthenticationSession shares the
        // persistent, system-wide web-credentials session — which already
        // has an active Google login (e.g. a personal account signed in
        // from browsing). Google then silently continues with that session
        // instead of rendering the "select_account" chooser, so a second
        // account (e.g. a work one) is never offered. Ephemeral forces a
        // clean session with no prior Google login, so the chooser (or
        // sign-in form) always appears and any account can be picked. The
        // cost — re-entering credentials on every sign-in — is fine here
        // since sign-in only happens once (or every ~7 days for
        // re-consent); we're not relying on this session to persist.
        session.prefersEphemeralWebBrowserSession = true
        self.webAuthSession = session
        session.start()
    }

    var isSignedIn: Bool {
        KeychainHelper.loadRefreshToken() != nil
    }

    /// Returns any meetings today whose event body contains a zoom.us link.
    func fetchTodaysZoomMeetings(completion rawCompletion: @escaping (Result<[CalendarMeeting], Error>) -> Void) {
        let completion: (Result<[CalendarMeeting], Error>) -> Void = { result in
            DispatchQueue.main.async { rawCompletion(result) }
        }
        ensureValidAccessToken { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let token):
                self.fetchEvents(accessToken: token, completion: completion)
            }
        }
    }

    // MARK: - Token exchange / refresh

    private func exchangeCodeForTokens(code: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            if let error { completion(.failure(error)); return }
            guard let data, let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
                completion(.failure(Self.tokenEndpointError(from: data, fallbackCode: 3)))
                return
            }
            self.accessToken = tokens.access_token
            self.accessTokenExpiry = Date().addingTimeInterval(TimeInterval(tokens.expires_in))
            if let refreshToken = tokens.refresh_token {
                KeychainHelper.saveRefreshToken(refreshToken)
            }
            completion(.success(()))
        }.resume()
    }

    /// Builds a descriptive NSError from a failed token endpoint response,
    /// pulling the OAuth `error`/`error_description` fields when present
    /// (e.g. "invalid_grant: Token has been expired or revoked.") instead
    /// of a generic, undiagnosable failure.
    private static func tokenEndpointError(from data: Data?, fallbackCode: Int) -> NSError {
        if let data, let oauthError = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data) {
            return NSError(domain: "GoogleCalendarService", code: fallbackCode,
                            userInfo: [NSLocalizedDescriptionKey: oauthError.friendlyMessage])
        }
        return NSError(domain: "GoogleCalendarService", code: fallbackCode,
                        userInfo: [NSLocalizedDescriptionKey: "Token request failed with an unrecognized response"])
    }

    private func ensureValidAccessToken(completion: @escaping (Result<String, Error>) -> Void) {
        if let token = accessToken, Date() < accessTokenExpiry.addingTimeInterval(-30) {
            completion(.success(token))
            return
        }
        guard let refreshToken = KeychainHelper.loadRefreshToken() else {
            completion(.failure(NSError(domain: "GoogleCalendarService", code: 4,
                                         userInfo: [NSLocalizedDescriptionKey: "Not signed in"])))
            return
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params = [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            if let error { completion(.failure(error)); return }
            guard let data, let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
                completion(.failure(Self.tokenEndpointError(from: data, fallbackCode: 5)))
                return
            }
            self.accessToken = tokens.access_token
            self.accessTokenExpiry = Date().addingTimeInterval(TimeInterval(tokens.expires_in))
            completion(.success(tokens.access_token))
        }.resume()
    }

    // MARK: - Events fetch + zoom link extraction

    private func fetchEvents(accessToken: String, completion: @escaping (Result<[CalendarMeeting], Error>) -> Void) {
        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let formatter = ISO8601DateFormatter()
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: startOfDay)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: endOfDay)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error { completion(.failure(error)); return }
            guard let data, let response = try? JSONDecoder().decode(GCalEventsResponse.self, from: data) else {
                if let data, let apiError = try? JSONDecoder().decode(GCalErrorResponse.self, from: data) {
                    completion(.failure(NSError(domain: "GoogleCalendarService", code: 6,
                                                 userInfo: [NSLocalizedDescriptionKey: apiError.friendlyMessage])))
                } else {
                    completion(.failure(NSError(domain: "GoogleCalendarService", code: 6,
                                                 userInfo: [NSLocalizedDescriptionKey: "Calendar events request failed with an unrecognized response"])))
                }
                return
            }

            logger.notice("fetchEvents: \(response.items.count) raw event(s) in [\(formatter.string(from: startOfDay), privacy: .public)..\(formatter.string(from: endOfDay), privacy: .public)]")

            let meetings: [CalendarMeeting] = response.items.compactMap { event in
                let title = event.summary ?? "Untitled meeting"

                guard event.status != "cancelled" else {
                    logger.notice("skip '\(title, privacy: .public)': cancelled")
                    return nil
                }
                guard let startString = event.start.dateTime, let endString = event.end.dateTime else {
                    logger.notice("skip '\(title, privacy: .public)': no dateTime (likely all-day event)")
                    return nil
                }
                guard let start = formatter.date(from: startString), let end = formatter.date(from: endString) else {
                    logger.notice("skip '\(title, privacy: .public)': failed to parse dateTime '\(startString, privacy: .public)' / '\(endString, privacy: .public)'")
                    return nil
                }

                let entryPointURIs = event.conferenceData?.entryPoints?.compactMap { $0.uri } ?? []
                let searchText = ([event.location, event.description, event.hangoutLink] + entryPointURIs)
                    .compactMap { $0 }
                    .joined(separator: " ")

                let joinURL: URL
                let provider: MeetingProvider
                if let zoomURL = Self.extractZoomURL(from: searchText) {
                    joinURL = zoomURL
                    provider = .zoom
                } else if let knoxURL = Self.extractKnoxMeetingURL(from: searchText) {
                    joinURL = knoxURL
                    provider = .knoxMeeting
                } else {
                    logger.notice("skip '\(title, privacy: .public)': no zoom.us/j/ or meeting.samsung.net link found. Searched text: \(searchText.isEmpty ? "<empty>" : searchText, privacy: .public)")
                    return nil
                }

                let isDeclined = event.attendees?.first(where: { $0.isSelf == true })?.responseStatus == "declined"

                logger.notice("match '\(title, privacy: .public)': \(start)–\(end), provider=\(String(describing: provider), privacy: .public), joinURL=\(joinURL.absoluteString, privacy: .public), declined=\(isDeclined)")

                return CalendarMeeting(
                    id: event.id,
                    title: title,
                    start: start,
                    end: end,
                    joinURL: joinURL,
                    provider: provider,
                    isDeclined: isDeclined
                )
            }

            completion(.success(meetings))
        }.resume()
    }

    // Matches everything up to whitespace or a quote/bracket, rather than an
    // allowlist of URL characters — invite links routinely contain percent-
    // encoding, `+`, `:`, `#`, etc. in their query strings, and a narrower
    // character class silently truncates the match at the first character
    // it doesn't recognize instead of failing loudly.
    private static let zoomLinkRegex = try! NSRegularExpression(
        pattern: #"https?://[a-zA-Z0-9.-]*zoom\.us/j/[^\s<>"']+"#
    )

    static func extractZoomURL(from text: String) -> URL? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = zoomLinkRegex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return URL(string: String(Self.trimmingTrailingPunctuation(text[swiftRange])))
    }

    /// Knox Meeting (Samsung's internal conferencing tool) invite links.
    /// We have no equivalent of `ZoomProcessMonitor` for it, so meetings
    /// matched here always alert regardless of call state — see
    /// `MeetingProvider.canDetectJoinState`.
    private static let knoxMeetingLinkRegex = try! NSRegularExpression(
        pattern: #"https?://[a-zA-Z0-9.-]*meeting\.samsung\.net[^\s<>"']*"#
    )

    static func extractKnoxMeetingURL(from text: String) -> URL? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = knoxMeetingLinkRegex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return URL(string: String(Self.trimmingTrailingPunctuation(text[swiftRange])))
    }

    /// Strips sentence punctuation (e.g. a trailing "." or ")") that the
    /// greedy character class above can pick up when a link is embedded in
    /// prose, like "join here: https://.../abc). Thanks!".
    private static func trimmingTrailingPunctuation(_ match: Substring) -> Substring {
        var trimmed = match
        while let last = trimmed.last, ".,;:)]}>\"'".contains(last) {
            trimmed = trimmed.dropLast()
        }
        return trimmed
    }
}

extension GoogleCalendarService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
