// Sources/RatchetCore/ElapsedTimeFormatter.swift
import Foundation

public enum ElapsedTimeFormatter {
    public static func format(seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        return String(format: "%d:%02d", hours, minutes)
    }
}
