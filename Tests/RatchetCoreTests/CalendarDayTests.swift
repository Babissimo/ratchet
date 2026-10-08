// SPDX-License-Identifier: GPL-3.0-or-later
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

    /// Counts calendar days, not 24-hour spans: an hour either side of midnight is a day apart.
    /// Mid-August, so no zone's daylight-saving change falls inside it.
    func testDaysBetweenCountsCalendarDays() throws {
        let day = try XCTUnwrap(CalendarDay.day(from: "2026-08-12"))
        let lateThatDay = day.addingTimeInterval(23 * 3600)
        let earlyNextDay = day.addingTimeInterval(25 * 3600)
        XCTAssertEqual(CalendarDay.daysBetween(day, and: lateThatDay), 0)
        XCTAssertEqual(CalendarDay.daysBetween(lateThatDay, and: earlyNextDay), 1)
        XCTAssertEqual(CalendarDay.daysBetween(earlyNextDay, and: lateThatDay), -1)
    }

    /// Havana's clocks go forward at midnight, so 8 March 2026 begins at 01:00 and is 23 hours
    /// long; it still counts as a whole day.
    func testDaysBetweenCountsADayWhoseMidnightIsSkipped() throws {
        let havana = try XCTUnwrap(TimeZone(identifier: "America/Havana"))
        let firstHour = try XCTUnwrap(makeDate(year: 2026, month: 3, day: 8, hour: 1, zone: havana))
        let lateThatDay = try XCTUnwrap(makeDate(year: 2026, month: 3, day: 8, hour: 23, zone: havana))
        let nextMorning = try XCTUnwrap(makeDate(year: 2026, month: 3, day: 9, hour: 9, zone: havana))
        XCTAssertEqual(CalendarDay.daysBetween(firstHour, and: lateThatDay, in: havana), 0)
        XCTAssertEqual(CalendarDay.daysBetween(firstHour, and: nextMorning, in: havana), 1)
    }

    /// Nothing for today or later, then "yesterday", a weekday for the rest of the past week, and
    /// the date from a week back, where a weekday would read as today's.
    func testPastDayDisplayStringNamesEachRangeOfDays() throws {
        let thursdayMorning = try XCTUnwrap(CalendarDay.day(from: "2026-08-13")).addingTimeInterval(9 * 3600)
        func name(_ text: String) throws -> String? {
            CalendarDay.pastDayDisplayString(from: try XCTUnwrap(CalendarDay.day(from: text)), now: thursdayMorning)
        }
        XCTAssertNil(try name("2026-08-14"))
        XCTAssertNil(try name("2026-08-13"))
        XCTAssertEqual(try name("2026-08-12"), "yesterday")
        XCTAssertEqual(try name("2026-08-11"), "Tuesday")
        XCTAssertEqual(try name("2026-08-07"), "Friday")
        let weekBack = try XCTUnwrap(CalendarDay.day(from: "2026-08-06"))
        XCTAssertEqual(try name("2026-08-06"), CalendarDay.displayString(from: weekBack))
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

    /// `CalendarDay` reads `TimeZone.current`, which ignores `NSTimeZone.default` but follows the
    /// `TZ` variable. Foundation caches the system zone, so `TZ` only takes effect after a reset.
    private func withTimeZone(_ zone: TimeZone, _ body: () throws -> Void) rethrows {
        let original = getenv("TZ").map { String(cString: $0) }
        setenv("TZ", zone.identifier, 1)
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let original { setenv("TZ", original, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
        }
        // Without this, a switch that silently fails leaves every test running in the machine's zone.
        XCTAssertEqual(TimeZone.current.identifier, zone.identifier, "failed to switch to \(zone.identifier)")
        try body()
    }
}
