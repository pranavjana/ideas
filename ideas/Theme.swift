import SwiftUI

#if os(macOS)
private typealias PlatformColor = NSColor
#else
private typealias PlatformColor = UIColor
#endif

extension Color {
    fileprivate static func adaptive(light: PlatformColor, dark: PlatformColor) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
        #endif
    }

    // MARK: - Backgrounds (darkest → lightest in dark mode)

    /// Deepest background (panels, chat area) — dark: 0.06, light: 1.0
    static let bgDeep = adaptive(
        light: PlatformColor(white: 1.0, alpha: 1),
        dark: PlatformColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1)
    )

    /// Sidebar background — dark: 0.07, light: 0.97
    static let bgSidebar = adaptive(
        light: PlatformColor(white: 0.97, alpha: 1),
        dark: PlatformColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
    )

    /// Panel background — dark: 0.08, light: 0.96
    static let bgPanel = adaptive(
        light: PlatformColor(white: 0.96, alpha: 1),
        dark: PlatformColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
    )

    /// Main background — dark: 0.09, light: 0.95
    static let bgBase = adaptive(
        light: PlatformColor(white: 0.95, alpha: 1),
        dark: PlatformColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 1)
    )

    /// Card/elevated background — dark: 0.11, light: 0.93
    static let bgElevated = adaptive(
        light: PlatformColor(white: 0.93, alpha: 1),
        dark: PlatformColor(red: 0.11, green: 0.11, blue: 0.11, alpha: 1)
    )

    /// Highest card background — dark: 0.12, light: 0.92
    static let bgCard = adaptive(
        light: PlatformColor(white: 0.92, alpha: 1),
        dark: PlatformColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
    )

    // MARK: - Foreground

    /// Adaptive foreground — white in dark, black in light
    static let fg = adaptive(
        light: PlatformColor(white: 0, alpha: 1),
        dark: PlatformColor(white: 1, alpha: 1)
    )

    // MARK: - System Color by Name

    /// Resolve a SwiftUI system color name (e.g. "red", "blue", "mint")
    static func systemColor(named name: String) -> Color? {
        switch name.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        default: return nil
        }
    }

    // MARK: - Adaptive Accent Colors

    /// Resolve a stored hex string into a mode-adaptive Color.
    /// Known preset hexes get perceptually-tuned light/dark variants
    /// (lighter + slightly desaturated in dark mode, richer in light mode).
    /// Unknown hexes are returned as-is.
    static func accent(hex: String) -> Color? {
        if let preset = AccentPalette.preset(for: hex) {
            return preset.color
        }
        return Color(hex: hex)
    }
}

// MARK: - Accent Palette

/// Predefined accent colors with perceptually-tuned light/dark variants.
/// Light mode: richer, lower lightness (~500-600 tone).
/// Dark mode: lighter, slightly desaturated (~300-400 tone).
/// Based on lightness-dependent chroma scaling principles.
struct AccentPalette {
    struct Preset {
        let base: String   // stored hex (identifier)
        let color: Color   // cached adaptive color
    }

    /// Notion-inspired presets with perceptually tuned light/dark variants
    static let presets: [Preset] = [
        makePreset("#787774", light: "#787774", dark: "#9B9B9B"),  // gray
        makePreset("#976D57", light: "#976D57", dark: "#A27763"),  // brown
        makePreset("#CC782F", light: "#CC782F", dark: "#CB7B37"),  // orange
        makePreset("#C29343", light: "#C29343", dark: "#C19138"),  // yellow
        makePreset("#548164", light: "#548164", dark: "#4F9768"),  // green
        makePreset("#487CA5", light: "#487CA5", dark: "#447ACB"),  // blue
        makePreset("#8A67AB", light: "#8A67AB", dark: "#865DBB"),  // purple
        makePreset("#B35488", light: "#B35488", dark: "#BA4A78"),  // pink
        makePreset("#C4554D", light: "#C4554D", dark: "#BE524B"),  // red
    ]

    private static func makePreset(_ base: String, light: String, dark: String) -> Preset {
        Preset(
            base: base,
            color: Color.adaptive(
                light: PlatformColor(Color(hex: light)!),
                dark: PlatformColor(Color(hex: dark)!)
            )
        )
    }

    /// All base hex values for use in picker UIs
    static let hexOptions: [String] = presets.map(\.base)

    /// O(1) lookup by uppercased base hex
    private static let presetMap: [String: Preset] = {
        Dictionary(uniqueKeysWithValues: presets.map { ($0.base.uppercased(), $0) })
    }()

    /// Look up a preset by its base hex
    static func preset(for hex: String) -> Preset? {
        presetMap[hex.uppercased()]
    }

    /// Get the adaptive Color for a preset by base hex
    static func color(for hex: String) -> Color? {
        preset(for: hex)?.color
    }
}
