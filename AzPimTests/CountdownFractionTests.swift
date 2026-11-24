@testable import AzPim
import Foundation
import Testing

/// The share of an activation still left, drawn by the iPhone dials.
struct CountdownFractionTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func followsTheTimeLeft() {
        let end = start.addingTimeInterval(4 * 3600)
        #expect(Countdown.fraction(start: start, end: end, now: start) == 1)
        #expect(Countdown.fraction(start: start, end: end, now: start.addingTimeInterval(3600)) == 0.75)
        #expect(Countdown.fraction(start: start, end: end, now: end) == 0)
    }

    @Test func staysWithinZeroAndOne() {
        let end = start.addingTimeInterval(3600)
        #expect(Countdown.fraction(start: start, end: end, now: end.addingTimeInterval(60)) == 0)
        #expect(Countdown.fraction(start: start, end: end, now: start.addingTimeInterval(-60)) == 1)
        // A clock skew can put the start after the end: no division by zero or a negative window.
        #expect(Countdown.fraction(start: end, end: start, now: start) == 0)
        #expect(Countdown.fraction(start: start, end: start, now: start) == 0)
    }

    @Test func noEndHasNoDial() {
        #expect(Countdown.fraction(start: start, end: nil, now: start) == nil)
    }
}
