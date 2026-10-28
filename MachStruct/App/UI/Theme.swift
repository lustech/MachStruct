import AppKit
import SwiftUI
import MachStructCore

// MARK: - Colours from the theme

extension ThemeColor {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255, alpha: 1)
    }
}

extension ColorTheme {

    /// The theme chosen in Settings, or the standard one.
    static var current: ColorTheme {
        UserDefaults.standard.string(forKey: AppSettings.Keys.colorTheme)
            .flatMap(ColorTheme.init(rawValue:)) ?? .standard
    }

    /// A colour of this theme that follows the appearance it is drawn in:
    /// the dark palette's in dark mode, the light palette's otherwise.
    func nsColor(_ role: KeyPath<ThemePalette, ThemeColor>) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return palette(dark: dark)[keyPath: role].nsColor
        }
    }

    func color(_ role: KeyPath<ThemePalette, ThemeColor>) -> Color {
        Color(nsColor: nsColor(role))
    }

    /// The colour for a scalar value.
    func color(for value: ScalarValue) -> Color { Color(nsColor: nsColor(for: value)) }

    func nsColor(for value: ScalarValue) -> NSColor {
        switch value {
        case .string:          return nsColor(\.string)
        case .integer, .float: return nsColor(\.number)
        case .boolean:         return nsColor(\.boolean)
        case .null:            return nsColor(\.null)
        }
    }
}

// MARK: - Environment

private struct ColorThemeKey: EnvironmentKey {
    static let defaultValue = ColorTheme.standard
}

extension EnvironmentValues {
    /// The document colour theme, set from Settings at the top of a document
    /// window so every row needn't read it.
    var colorTheme: ColorTheme {
        get { self[ColorThemeKey.self] }
        set { self[ColorThemeKey.self] = newValue }
    }
}
