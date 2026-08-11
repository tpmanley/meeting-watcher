//
//  Meeting_WatcherTests.swift
//  Meeting WatcherTests
//
//  Created by Tom Manley on 7/29/26.
//

import Foundation
import Testing
@testable import Meeting_Watcher

struct Meeting_WatcherTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        // Swift Testing Documentation
        // https://developer.apple.com/documentation/testing
    }

    @Test func extractsKnoxMeetingURLWithAtSign() throws {
        let text = "Join here: https://meeting.samsung.net/@/j/12345678 See you there."
        let url = GoogleCalendarService.extractKnoxMeetingURL(from: text)
        #expect(url?.absoluteString == "https://meeting.samsung.net/@/j/12345678")
    }

    @Test func extractsZoomURLWithQueryString() throws {
        let text = "https://us02web.zoom.us/j/1234567890?pwd=abc%3D%3D+def#success"
        let url = GoogleCalendarService.extractZoomURL(from: text)
        #expect(url?.absoluteString == "https://us02web.zoom.us/j/1234567890?pwd=abc%3D%3D+def#success")
    }

}
