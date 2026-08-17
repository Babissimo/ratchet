import Foundation

public enum DurationFormatter {
    /// Parses "H:MM" (e.g. "1:30") into decimal hours (e.g. 1.5). Returns nil for malformed
    /// input, negative values, minutes outside 0..<60, or a total over 24 hours (a single
    /// timeslip can't sensibly exceed a full day — this also catches likely typos like "10:30"
    /// meant as "1:30").
    public static func parseHoursAndMinutes(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hours = Int(parts[0]), hours >= 0,
              let minutes = Int(parts[1]), minutes >= 0, minutes < 60,
              hours > 0 || minutes > 0
        else { return nil }
        let total = Double(hours) + Double(minutes) / 60.0
        guard total <= 24 else { return nil }
        return total
    }

    /// The inverse of `parseHoursAndMinutes`, for prefilling a duration field from a stored
    /// value (e.g. the edit-time-entry form) — round-trips through the same "H:MM" shape rather
    /// than a decimal, so what the user sees matches what they'd type.
    public static func hoursAndMinutes(_ hours: Double) -> String {
        // Clamped to at least one minute whenever `hours` is positive: a duration under 30
        // seconds rounds to 0 total minutes, which `parseHoursAndMinutes` rejects (it requires
        // hours > 0 || minutes > 0) — round-tripping a real, if tiny, logged duration through
        // this formatter must never produce text its own parser calls invalid.
        let rounded = Int((hours * 60).rounded())
        let totalMinutes = hours > 0 ? max(1, rounded) : rounded
        return "\(totalMinutes / 60):" + String(format: "%02d", totalMinutes % 60)
    }
}
