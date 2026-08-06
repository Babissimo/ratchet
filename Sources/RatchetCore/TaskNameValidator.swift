// Sources/RatchetCore/TaskNameValidator.swift
import Foundation

public enum TaskNameValidator {
    public static func validate(_ rawInput: String) -> String? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
