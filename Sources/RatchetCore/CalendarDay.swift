// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Conversions for FreeAgent's `dated_on`-style calendar dates ("2026-08-12").
///
/// These are *plain days*, not instants: "the day you did the work". They therefore have to be
/// formatted and parsed in the user's own time zone. Formatting in UTC (as every call site here
/// used to) books a Los Angeles user's 17:00 entry to the following day, and makes an Auckland
/// user's "today" resolve to yesterday.
///
/// `dayString`/`day(from:)` are exact inverses in the current zone, so a date that round-trips
/// through FreeAgent still displays as the day the user picked.
public enum CalendarDay {
    /// The calendar day `date` falls on, in the current time zone, as "yyyy-MM-dd".
    public static func dayString(from date: Date) -> String {
        dayFormatter().string(from: date)
    }

    /// Parses "yyyy-MM-dd" into local midnight of that day. Returns nil if `text` isn't a
    /// well-formed date in that exact format.
    public static func day(from text: String) -> Date? {
        dayFormatter().date(from: text)
    }

    /// A calendar day rendered for display (e.g. "12 Aug 2026"), in the current time zone and
    /// the user's own locale/format preferences.
    public static func displayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// Whole calendar days from the day `day` falls on to the day `now` falls on, in `zone`: 0 for
    /// the same day, 1 when `day` is yesterday, negative when `day` is later.
    static func daysBetween(_ day: Date, and now: Date, in zone: TimeZone = .current) -> Int {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        // Diffed as UTC dates: where the clocks go forward at midnight the local day begins at
        // 01:00, and its 23 hours to the next midnight would count as no day at all.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        guard let start = utc.date(from: local.dateComponents([.year, .month, .day], from: day)),
              let end = utc.date(from: local.dateComponents([.year, .month, .day], from: now))
        else { return 0 }
        return utc.dateComponents([.day], from: start, to: end).day ?? 0
    }

    /// `day` named relative to `now` if it is earlier: "yesterday", its weekday within the past
    /// week, otherwise `displayString(from:)`. Nil for today or a later day.
    ///
    /// The weekday is English, like the menu text it sits in; an older date follows the user's
    /// own format, as everywhere else the app shows one.
    static func pastDayDisplayString(from day: Date, now: Date) -> String? {
        switch daysBetween(day, and: now) {
        case ...0:
            return nil
        case 1:
            return "yesterday"
        case 2...6:
            let formatter = dayFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: day)
        default:
            return displayString(from: day)
        }
    }

    /// Built per call rather than cached in a `static let`.
    ///
    /// A cached formatter captures `TimeZone.current` at first use, so it would keep emitting the
    /// old day after the user travels or the system zone changes — the exact class of bug this
    /// type exists to remove. Constructing one costs microseconds against menu builds and network
    /// round trips, and sidesteps `DateFormatter`'s mutation-thread-safety rules entirely.
    ///
    /// `en_US_POSIX` is required, not cosmetic: without it a fixed `dateFormat` is still rendered
    /// through the user's locale, so a preference for Arabic-Indic or Devanagari digits produces
    /// "٢٠٢٦-٠٨-١٢" — which FreeAgent rejects.
    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
