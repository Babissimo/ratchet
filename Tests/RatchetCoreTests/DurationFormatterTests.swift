import XCTest
@testable import RatchetCore

final class DurationFormatterTests: XCTestCase {
    func test_oneThirty_parsesToOnePointFive() {
        XCTAssertEqual(DurationFormatter.parseHoursAndMinutes("1:30"), 1.5)
    }

    func test_zeroFifteen_parsesToQuarterHour() {
        XCTAssertEqual(DurationFormatter.parseHoursAndMinutes("0:15"), 0.25)
    }

    func test_wholeHours_parsesCorrectly() {
        XCTAssertEqual(DurationFormatter.parseHoursAndMinutes("2:00"), 2.0)
    }

    func test_zeroZero_isInvalid() {
        XCTAssertNil(DurationFormatter.parseHoursAndMinutes("0:00"))
    }

    func test_minutesSixty_isInvalid() {
        XCTAssertNil(DurationFormatter.parseHoursAndMinutes("1:60"))
    }

    func test_negativeHours_isInvalid() {
        XCTAssertNil(DurationFormatter.parseHoursAndMinutes("-1:00"))
    }

    func test_malformedText_isInvalid() {
        XCTAssertNil(DurationFormatter.parseHoursAndMinutes("not a duration"))
        XCTAssertNil(DurationFormatter.parseHoursAndMinutes("1.5"))
        XCTAssertNil(DurationFormatter.parseHoursAndMinutes(""))
    }

    func test_whitespaceIsTrimmed() {
        XCTAssertEqual(DurationFormatter.parseHoursAndMinutes("  1:30  "), 1.5)
    }

    func test_exactlyTwentyFourHours_isValid() {
        XCTAssertEqual(DurationFormatter.parseHoursAndMinutes("24:00"), 24.0)
    }

    func test_overTwentyFourHours_isInvalid() {
        XCTAssertNil(DurationFormatter.parseHoursAndMinutes("24:01"))
        XCTAssertNil(DurationFormatter.parseHoursAndMinutes("25:00"))
    }
}
