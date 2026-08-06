// Tests/RatchetCoreTests/ElapsedTimeFormatterTests.swift
import XCTest
@testable import RatchetCore

final class ElapsedTimeFormatterTests: XCTestCase {
    func test_zeroSeconds_formatsAsZeroZero() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: 0), "0:00")
    }

    func test_ninetySeconds_formatsAsOneMinute() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: 90), "0:01")
    }

    func test_sixThousandFourHundredTwentySeconds_formatsAsOneFortySeven() {
        // 1 hour 47 minutes, matching the spec's tracking screen example
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: 6420), "1:47")
    }

    func test_negativeSeconds_clampsToZero() {
        XCTAssertEqual(ElapsedTimeFormatter.format(seconds: -5), "0:00")
    }
}
