import Foundation

// MARK: - ScalarInsights

/// Lightweight format detection for scalar values shown in the tree.
///
/// Inspects a `ScalarValue` for "secondary meanings" — patterns that look
/// like base64 payloads, Unix timestamps, UUIDs, hex colours, or ISO 8601
/// datetimes — and surfaces them so the UI can show a popover with the
/// decoded form.
///
/// Detection is deliberately conservative: we only flag values that match
/// well-known patterns precisely, to keep false positives low (the user
/// shouldn't see a "this looks like a timestamp" hint on every 10-digit
/// integer that happens to fit the range).
public struct ScalarInsights: Sendable, Equatable {
    public var unixTimestamp: Date?
    public var iso8601Date:   Date?
    public var uuid:          UUID?
    public var hexColor:      HexColor?
    public var base64Preview: Base64Preview?

    /// True when at least one inspector matched.
    public var hasAny: Bool {
        unixTimestamp != nil
            || iso8601Date != nil
            || uuid != nil
            || hexColor != nil
            || base64Preview != nil
    }
}

// MARK: - Sub-types

extension ScalarInsights {

    /// A detected `#RRGGBB` (or `#RGB`) colour.
    public struct HexColor: Sendable, Equatable {
        public let hex: String           // canonicalised "#RRGGBB"
        public let red:   Double         // 0...1
        public let green: Double
        public let blue:  Double
    }

    /// Decoded base64 payload preview (first 64 bytes).
    public struct Base64Preview: Sendable, Equatable {
        public let totalBytes: Int
        public let firstBytesHex: String   // up to 64 bytes, space-separated
        public let firstBytesUTF8: String? // nil when bytes don't decode as UTF-8
    }
}

// MARK: - Detection entry point

extension ScalarValue {

    /// Returns a populated `ScalarInsights` when one or more patterns match,
    /// or `nil` when nothing was detected.
    ///
    /// Costly inspectors (base64 decode) are guarded by cheap pattern checks
    /// so calling this on every row in a busy tree is safe.
    public func inspect() -> ScalarInsights? {
        var out = ScalarInsights()

        switch self {
        case .integer(let n):
            // 10-digit (seconds) or 13-digit (milliseconds) Unix timestamp,
            // bounded to 2001…2100 to avoid flagging arbitrary integers.
            out.unixTimestamp = ScalarInsightsDetect.unixTimestamp(int: n)

        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespaces)

            // ISO 8601 / RFC 3339 datetimes (`2026-04-27T14:32:11Z`, etc.)
            out.iso8601Date = ScalarInsightsDetect.iso8601(trimmed)

            // Numeric strings can also be Unix timestamps.
            if let n = Int64(trimmed) {
                out.unixTimestamp = ScalarInsightsDetect.unixTimestamp(int: n)
            }

            out.uuid          = ScalarInsightsDetect.uuid(trimmed)
            out.hexColor      = ScalarInsightsDetect.hexColor(trimmed)
            out.base64Preview = ScalarInsightsDetect.base64Preview(trimmed)

        case .float, .boolean, .null:
            break
        }

        return out.hasAny ? out : nil
    }
}

// MARK: - Detection internals

enum ScalarInsightsDetect {

    // -- Unix timestamp --------------------------------------------------

    /// Heuristic: 10 digits (seconds since 1970) or 13 digits (milliseconds)
    /// inside the range 2001-01-01 … 2100-01-01.  This filters out random
    /// 10-digit numbers that don't correspond to a plausible date.
    static func unixTimestamp(int n: Int64) -> Date? {
        let secondsLow:  Int64 =  978_307_200   // 2001-01-01
        let secondsHigh: Int64 = 4_102_444_800  // 2100-01-01

        if n >= secondsLow, n <= secondsHigh {
            return Date(timeIntervalSince1970: TimeInterval(n))
        }

        // Milliseconds-since-epoch: 13 digits, divide by 1000.
        let msLow  = secondsLow  * 1000
        let msHigh = secondsHigh * 1000
        if n >= msLow, n <= msHigh {
            return Date(timeIntervalSince1970: TimeInterval(Double(n) / 1000.0))
        }
        return nil
    }

    // -- ISO 8601 --------------------------------------------------------

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601FormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func iso8601(_ s: String) -> Date? {
        // Cheap gate: must contain a digit, "T", and end with Z or have ±HH:MM.
        guard s.count >= 10, s.contains("-") else { return nil }
        if let d = iso8601Formatter.date(from: s)            { return d }
        if let d = iso8601FormatterNoFraction.date(from: s)  { return d }
        return nil
    }

    // -- UUID ------------------------------------------------------------

    static func uuid(_ s: String) -> UUID? {
        guard s.count == 36 else { return nil }
        return UUID(uuidString: s)
    }

    // -- Hex colour ------------------------------------------------------

    static func hexColor(_ s: String) -> ScalarInsights.HexColor? {
        guard s.hasPrefix("#") else { return nil }
        let hex = String(s.dropFirst())
        let canonical: String
        switch hex.count {
        case 6:
            canonical = hex
        case 3:
            // Expand `#abc` → `aabbcc`.
            canonical = hex.map { "\($0)\($0)" }.joined()
        default:
            return nil
        }
        guard canonical.allSatisfy({ $0.isHexDigit }) else { return nil }
        let r = UInt8(canonical.prefix(2),                            radix: 16)
        let g = UInt8(canonical.dropFirst(2).prefix(2),               radix: 16)
        let b = UInt8(canonical.suffix(2),                            radix: 16)
        guard let r, let g, let b else { return nil }
        return ScalarInsights.HexColor(
            hex:   "#\(canonical.uppercased())",
            red:   Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue:  Double(b) / 255.0
        )
    }

    // -- Base64 ----------------------------------------------------------

    /// We require ≥16 chars (4-char base64 chunk × 4) to suppress short
    /// false positives like "abcd".  Length must be divisible by 4 and the
    /// alphabet must be standard.
    private static let base64Regex: NSRegularExpression = {
        // Matches the standard base64 alphabet with optional `=` padding.
        try! NSRegularExpression(pattern: "^[A-Za-z0-9+/]+={0,2}$")
    }()

    static func base64Preview(_ s: String) -> ScalarInsights.Base64Preview? {
        guard s.count >= 16, s.count % 4 == 0 else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard base64Regex.firstMatch(in: s, range: range) != nil else { return nil }
        guard let data = Data(base64Encoded: s, options: []) else { return nil }
        let preview = data.prefix(64)
        let hex = preview.map { String(format: "%02x", $0) }.joined(separator: " ")
        let utf8 = String(data: preview, encoding: .utf8)
        return ScalarInsights.Base64Preview(
            totalBytes:     data.count,
            firstBytesHex:  hex,
            firstBytesUTF8: utf8
        )
    }
}
