// SPDX-License-Identifier: GPL-3.0-or-later
// Tests/RatchetCoreTests/TaskNameValidatorTests.swift
import XCTest
@testable import RatchetCore

final class TaskNameValidatorTests: XCTestCase {
    func test_emptyString_isInvalid() {
        XCTAssertNil(TaskNameValidator.validate(""))
    }

    func test_whitespaceOnly_isInvalid() {
        XCTAssertNil(TaskNameValidator.validate("   \n  "))
    }

    func test_trimsSurroundingWhitespace() {
        XCTAssertEqual(TaskNameValidator.validate("  Design  "), "Design")
    }

    func test_validName_isReturnedUnchanged() {
        XCTAssertEqual(TaskNameValidator.validate("QA"), "QA")
    }
}
