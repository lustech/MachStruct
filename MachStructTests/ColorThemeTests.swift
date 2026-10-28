import XCTest
@testable import MachStructCore

/// Document colour themes: every colour must stay readable on its background
/// in both appearances, which is what the grey sidebar background and orange
/// strings they replace failed at.
final class ColorThemeTests: XCTestCase {

    func testEveryThemeIsReadableInBothAppearances() {
        for theme in ColorTheme.allCases {
            for dark in [false, true] {
                let palette = theme.palette(dark: dark)
                for (name, color, minimum) in palette.textColors {
                    let contrast = color.contrast(with: palette.background)
                    XCTAssertGreaterThanOrEqual(
                        contrast, minimum,
                        "\(theme.displayName) \(dark ? "dark" : "light") \(name): \(String(format: "%.2f", contrast)):1")
                }
            }
        }
    }

    func testDarkPalettesAreDarkAndLightPalettesLight() {
        for theme in ColorTheme.allCases {
            XCTAssertLessThan(theme.dark.background.relativeLuminance, 0.05, theme.displayName)
            XCTAssertGreaterThan(theme.light.background.relativeLuminance, 0.9, theme.displayName)
        }
    }

    func testContrastMatchesWCAG() {
        let black = ThemeColor(0x000000), white = ThemeColor(0xFFFFFF)
        XCTAssertEqual(black.contrast(with: white), 21, accuracy: 0.01)
        XCTAssertEqual(white.contrast(with: black), 21, accuracy: 0.01)
        XCTAssertEqual(white.contrast(with: white), 1, accuracy: 0.001)
        // WCAG's own example: #777777 on white is just under 4.5:1.
        XCTAssertEqual(ThemeColor(0x777777).contrast(with: white), 4.48, accuracy: 0.01)
    }

    func testHexComponents() {
        let color = ThemeColor(0x9CDCFE)
        XCTAssertEqual([color.red, color.green, color.blue], [0x9C, 0xDC, 0xFE])
    }

    /// The setting is saved by raw value, so renaming a case would reset
    /// everyone's choice.
    func testThemeIdentifiersAreStable() {
        XCTAssertEqual(ColorTheme.allCases.map(\.rawValue), ["darkPlus", "xcode", "oneDark"])
        XCTAssertEqual(ColorTheme.standard, .darkPlus)
        XCTAssertEqual(ColorTheme.allCases.map(\.displayName), ["Dark+", "Xcode", "One Dark"])
    }
}
