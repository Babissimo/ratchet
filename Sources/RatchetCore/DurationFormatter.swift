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
}
