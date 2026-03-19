import Foundation
import SwiftUI
import SwiftData

extension AppSchemaV2 {
@Model
final class UserProfile {
    var bio: String
    var verifiedTags: [String]
    var tagColors: [String: String] = [:]  // tag name → hex color string
    var appleCalendarSyncEnabled: Bool

    init() {
        self.bio = ""
        self.verifiedTags = []
        self.tagColors = [:]
        self.appleCalendarSyncEnabled = false
    }

    var hasProfile: Bool {
        !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func color(for tag: String) -> Color? {
        guard let hex = tagColors[tag], !hex.isEmpty else { return nil }
        return Color.accent(hex: hex)
    }

    func setColor(_ color: Color?, for tag: String) {
        if let color {
            tagColors[tag] = color.toHex()
        } else {
            tagColors.removeValue(forKey: tag)
        }
    }
}
}

// MARK: - Color ↔ Hex

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let int = UInt64(h, radix: 16) else { return nil }
        self.init(
            red: Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8) & 0xFF) / 255,
            blue: Double(int & 0xFF) / 255
        )
    }

    func toHex() -> String {
        #if os(macOS)
        guard let components = NSColor(self).usingColorSpace(.deviceRGB) else { return "" }
        let r = Int(components.redComponent * 255)
        let g = Int(components.greenComponent * 255)
        let b = Int(components.blueComponent * 255)
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: nil)
        let r = Int(red * 255), g = Int(green * 255), b = Int(blue * 255)
        #endif
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
