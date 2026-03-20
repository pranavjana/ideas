import Foundation

enum UserSettings {
    static let displayNameKey = "user_display_name"

    static func normalizedDisplayName(from rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
