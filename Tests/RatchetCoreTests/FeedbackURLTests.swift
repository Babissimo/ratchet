// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import RatchetCore

final class FeedbackURLTests: XCTestCase {
    private let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 1)

    private func body(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "body" })?.value
    }

    func test_newIssue_opensTheRepositorysNewIssueForm() {
        let url = FeedbackURL.newIssue(appVersion: "1.2.0", systemVersion: sonoma)

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/Babissimo/ratchet/issues/new")
    }

    func test_newIssue_prefillsAppAndSystemVersionsBelowABlankLine() {
        let url = FeedbackURL.newIssue(appVersion: "1.2.0", systemVersion: sonoma)

        XCTAssertEqual(body(of: url), "\n\n---\nRatchet 1.2.0 · macOS 14.6.1")
    }

    // `swift run` launches the bare binary, which has no Info.plist to read a version from.
    func test_newIssue_saysUnknownWithoutABundleVersion() {
        let url = FeedbackURL.newIssue(appVersion: nil, systemVersion: sonoma)

        XCTAssertEqual(body(of: url), "\n\n---\nRatchet unknown · macOS 14.6.1")
    }
}
