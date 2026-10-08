// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Where "Send feedback" goes: a new issue on the public GitHub repository, so feedback needs no
/// service of Ratchet's own to receive it.
public enum FeedbackURL {
    /// The new-issue form with the app and macOS versions already in the body, since a report
    /// without them usually costs a round trip to ask.
    public static func newIssue(
        appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> URL {
        let system = "\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)"
        var components = URLComponents(string: "https://github.com/Babissimo/ratchet/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "body", value: "\n\n---\nRatchet \(appVersion ?? "unknown") · macOS \(system)"),
        ]
        return components.url!
    }
}
