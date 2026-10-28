import Foundation

// MARK: - ThemeColor

/// An sRGB colour as the themes define it, with the contrast arithmetic the
/// themes are checked against. UI types are built from it in the app.
public struct ThemeColor: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    /// `0xRRGGBB`.
    public init(_ hex: UInt32) {
        red = UInt8(hex >> 16 & 0xFF)
        green = UInt8(hex >> 8 & 0xFF)
        blue = UInt8(hex & 0xFF)
    }

    /// WCAG 2 relative luminance, from 0 (black) to 1 (white).
    public var relativeLuminance: Double {
        func channel(_ value: UInt8) -> Double {
            let v = Double(value) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG 2 contrast ratio with `other`, from 1 to 21.
    public func contrast(with other: ThemeColor) -> Double {
        let (lighter, darker) = relativeLuminance >= other.relativeLuminance
            ? (relativeLuminance, other.relativeLuminance)
            : (other.relativeLuminance, relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

// MARK: - ThemePalette

/// The colours of one appearance (light or dark) of a theme: the document
/// background and the text drawn on it.
public struct ThemePalette: Hashable, Sendable {
    public let background: ThemeColor
    /// Object keys, CSV headers and YAML mapping keys.
    public let key: ThemeColor
    public let string: ThemeColor
    public let number: ThemeColor
    public let boolean: ThemeColor
    public let null: ThemeColor
    /// XML element names.
    public let tag: ThemeColor
    /// XML attribute names.
    public let attribute: ThemeColor
    /// Punctuation and summaries such as `{4 keys}`.
    public let muted: ThemeColor
    public let comment: ThemeColor

    /// The colours drawn as text, with the contrast each needs against the
    /// background: 4.5:1 for values (WCAG AA for body text), 3:1 for
    /// secondary text.
    public var textColors: [(name: String, color: ThemeColor, minimumContrast: Double)] {
        [("key", key, 4.5), ("string", string, 4.5), ("number", number, 4.5),
         ("boolean", boolean, 4.5), ("null", null, 4.5), ("tag", tag, 4.5),
         ("attribute", attribute, 4.5), ("muted", muted, 3), ("comment", comment, 3)]
    }
}

// MARK: - ColorTheme

/// The colour schemes documents can be shown in, each with a light and a dark
/// palette that follow the system appearance.
public enum ColorTheme: String, CaseIterable, Identifiable, Sendable {
    /// After Visual Studio Code's Dark+ and Light+: the JSON colours most
    /// developers know.
    case darkPlus
    /// After Xcode's default dark and light themes.
    case xcode
    /// After Atom's One Dark and One Light, adjusted for contrast.
    case oneDark

    public static let standard = ColorTheme.darkPlus

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .darkPlus: return "Dark+"
        case .xcode:    return "Xcode"
        case .oneDark:  return "One Dark"
        }
    }

    public func palette(dark: Bool) -> ThemePalette { dark ? self.dark : light }

    public var dark: ThemePalette {
        switch self {
        case .darkPlus:
            return ThemePalette(background: ThemeColor(0x1E1E1E), key: ThemeColor(0x9CDCFE),
                                string: ThemeColor(0xCE9178), number: ThemeColor(0xB5CEA8),
                                boolean: ThemeColor(0x569CD6), null: ThemeColor(0x569CD6),
                                tag: ThemeColor(0x569CD6), attribute: ThemeColor(0x9CDCFE),
                                muted: ThemeColor(0x858585), comment: ThemeColor(0x6A9955))
        case .xcode:
            return ThemePalette(background: ThemeColor(0x1F1F24), key: ThemeColor(0x6BDFFF),
                                string: ThemeColor(0xFC6A5D), number: ThemeColor(0xD0BF69),
                                boolean: ThemeColor(0xFC5FA3), null: ThemeColor(0xFC5FA3),
                                tag: ThemeColor(0x5DD8FF), attribute: ThemeColor(0xD0A8FF),
                                muted: ThemeColor(0x7F8C98), comment: ThemeColor(0x6C7986))
        case .oneDark:
            return ThemePalette(background: ThemeColor(0x282C34), key: ThemeColor(0xE5838B),
                                string: ThemeColor(0x98C379), number: ThemeColor(0xD19A66),
                                boolean: ThemeColor(0x56B6C2), null: ThemeColor(0xC678DD),
                                tag: ThemeColor(0xE5838B), attribute: ThemeColor(0xD19A66),
                                muted: ThemeColor(0x8B919C), comment: ThemeColor(0x8B919C))
        }
    }

    public var light: ThemePalette {
        switch self {
        case .darkPlus:
            return ThemePalette(background: ThemeColor(0xFFFFFF), key: ThemeColor(0x0451A5),
                                string: ThemeColor(0xA31515), number: ThemeColor(0x098658),
                                boolean: ThemeColor(0x0000FF), null: ThemeColor(0x0000FF),
                                tag: ThemeColor(0x800000), attribute: ThemeColor(0xE50000),
                                muted: ThemeColor(0x6E6E6E), comment: ThemeColor(0x008000))
        case .xcode:
            return ThemePalette(background: ThemeColor(0xFFFFFF), key: ThemeColor(0x0F68A0),
                                string: ThemeColor(0xC41A16), number: ThemeColor(0x1C00CF),
                                boolean: ThemeColor(0x9B2393), null: ThemeColor(0x9B2393),
                                tag: ThemeColor(0x0B4F79), attribute: ThemeColor(0x815F03),
                                muted: ThemeColor(0x6C6C70), comment: ThemeColor(0x5D6C79))
        case .oneDark:
            return ThemePalette(background: ThemeColor(0xFAFAFA), key: ThemeColor(0xC4402F),
                                string: ThemeColor(0x3B7D3A), number: ThemeColor(0x8A5D00),
                                boolean: ThemeColor(0x0A6F96), null: ThemeColor(0xA626A4),
                                tag: ThemeColor(0xC4402F), attribute: ThemeColor(0x8A5D00),
                                muted: ThemeColor(0x696C77), comment: ThemeColor(0x696C77))
        }
    }
}
