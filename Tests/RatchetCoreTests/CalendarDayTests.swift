import XCTest
@testable import RatchetCore

final class CalendarDayTests: XCTestCase {
    /// The whole point of the type: a day written out and read back is the same day, whatever
    /// zone the user is in. Run against zones either side of UTC, since the old UTC-pinned
    /// formatters failed in opposite directions.
    func testDayStringRoundTripsInBothHemispheres() throws {
        for identifier in ["America/Los_Angeles", "Pacific/Auckland", "UTC", "Asia/Kolkata"] {
            let zone = try XCTUnwrap(TimeZone(identifier: identifier))
            try withTimeZone(zone) {
                let parsed = try XCTUnwrap(CalendarDay.day(from: "2026-08-12"))
                XCTAssertEqual(CalendarDay.dayString(from: parsed), "2026-08-12", "round trip failed in \(identifier)")
            }
        }
    }

    /// An evening in Los Angeles is already tomorrow in UTC — the bug that booked time to the
    /// wrong day. 17:00 on the 12th must stay the 12th.
    func testEveningWestOfUTCKeepsTheLocalDay() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        try withTimeZone(zone) {
            let evening = try XCTUnwrap(makeDate(year: 2026, month: 8, day: 12, hour: 17, zone: zone))
            XCTAssertEqual(CalendarDay.dayString(from: evening), "2026-08-12")
        }
    }

    /// A morning in Auckland is still yesterday in UTC — the mirror-image failure, which made
    /// `todayString()` miss today's existing timeslip and create a duplicate.
    func testMorningEastOfUTCKeepsTheLocalDay() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        try withTimeZone(zone) {
            let morning = try XCTUnwrap(makeDate(year: 2026, month: 8, day: 12, hour: 9, zone: zone))
            XCTAssertEqual(CalendarDay.dayString(from: morning), "2026-08-12")
        }
    }

    /// A parsed day displays as that same day, rather than slipping back one because the value
    /// was UTC midnight rendered in a western zone.
    func testParsedDayDisplaysAsTheSameDay() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        try withTimeZone(zone) {
            let parsed = try XCTUnwrap(CalendarDay.day(from: "2026-08-12"))
            XCTAssertTrue(CalendarDay.displayString(from: parsed).contains("12"))
            XCTAssertFalse(CalendarDay.displayString(from: parsed).contains("11"))
        }
    }

    /// A fixed `dateFormat` is still rendered through the user's locale unless it's POSIX-pinned,
    /// so a non-Latin numbering preference would otherwise emit digits FreeAgent rejects.
    func testEmitsASCIIDigitsUnderANonLatinNumberingLocale() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        try withTimeZone(zone) {
            let day = try XCTUnwrap(CalendarDay.day(from: "2026-08-12"))
            XCTAssertEqual(CalendarDay.dayString(from: day), "2026-08-12")
            XCTAssertTrue(CalendarDay.dayString(from: day).allSatisfy { $0.isASCII })
        }
    }

    func testRejectsMalformedInput() {
        XCTAssertNil(CalendarDay.day(from: ""))
        XCTAssertNil(CalendarDay.day(from: "not a date"))
        XCTAssertNil(CalendarDay.day(from: "12/08/2026"))
    }

    // MARK: - Helpers

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, zone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
    }

    /// `CalendarDay` reads `TimeZone.current`, so exercising other zones means swapping the
    /// process default for the duration of the block.
    private func withTimeZone(_ zone: TimeZone, _ body: () throws -> Void) rethrows {
        let original = NSTimeZone.default
        NSTimeZone.default = zone
        defer { NSTimeZone.default = original }
        try body()
    }
}
