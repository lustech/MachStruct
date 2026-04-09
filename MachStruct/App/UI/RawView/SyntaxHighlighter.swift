import AppKit
import SwiftUI

// MARK: - SyntaxHighlighter

/// Applies lightweight regex-based syntax colouring to serialised document text.
///
/// Uses `NSMutableAttributedString` internally (fast, stable range API) and
/// converts to `AttributedString` for SwiftUI `Text` rendering.
///
/// Highlighting is skipped for text longer than `limit` characters so the UI
/// stays responsive on very large files.  Callers should invoke `highlight` on
/// a background thread (`Task.detached`).
struct SyntaxHighlighter {

    // MARK: - Format

    enum Format {
        case json, xml, yaml, csv

        init?(formatName: String) {
            switch formatName.uppercased() {
            case "JSON": self = .json
            case "XML":  self = .xml
            case "YAML": self = .yaml
            case "CSV":  self = .csv
            default:     return nil
            }
        }
    }

    /// Characters beyond this limit are returned as plain monospaced text.
    static let limit = 150_000

    // MARK: - Public API

    /// Returns an `AttributedString` with syntax colours applied.
    ///
    /// Safe to call from any thread.
    static func highlight(_ text: String, format: Format) -> AttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let ns   = NSMutableAttributedString(string: text)
        ns.addAttribute(.font, value: mono,
                        range: NSRange(location: 0, length: ns.length))

        if text.count <= limit {
            switch format {
            case .json: applyJSON(to: ns)
            case .xml:  applyXML(to: ns)
            case .yaml: applyYAML(to: ns)
            case .csv:  applyCSV(to: ns)
            }
        }

        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(text)
    }

    // MARK: - JSON

    private static func applyJSON(to ns: NSMutableAttributedString) {
        let src = ns.string

        // 1. Numbers (lowest priority — overwritten by later passes)
        paint(pattern: #"-?\b\d+(\.\d+)?([eE][+-]?\d+)?\b"#,
              color: .systemPurple, in: ns, source: src)

        // 2. Keywords
        paint(pattern: #"\b(true|false|null)\b"#,
              color: .systemRed, in: ns, source: src)

        // 3. All quoted strings → orange (value colour)
        paint(pattern: #""(?:[^"\\]|\\.)*""#,
              color: .systemOrange, in: ns, source: src)

        // 4. Object keys (quoted string immediately before a colon) → blue
        //    Paint range includes the trailing colon — we strip it below.
        paintKeys(in: ns, source: src)
    }

    /// Paints JSON object keys blue.  Matches `"key"\s*:` but colours only
    /// the string portion, not the colon.
    private static func paintKeys(in ns: NSMutableAttributedString,
                                  source: String) {
        guard let rx = try? NSRegularExpression(
            pattern: #""(?:[^"\\]|\\.)*"\s*:"#) else { return }
        let nsSource = source as NSString
        rx.enumerateMatches(in: source, range: NSRange(location: 0, length: nsSource.length)) { m, _, _ in
            guard let m else { return }
            // Find the closing quote of the key within the match.
            let matchStr = nsSource.substring(with: m.range)
            if let closeQuote = matchStr.range(of: "\"", options: .backwards,
                                               range: matchStr.index(after: matchStr.startIndex)..<matchStr.endIndex) {
                let keyLen = matchStr.distance(from: matchStr.startIndex, to: closeQuote.upperBound)
                let keyRange = NSRange(location: m.range.location, length: keyLen)
                ns.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: keyRange)
            }
        }
    }

    // MARK: - XML

    private static func applyXML(to ns: NSMutableAttributedString) {
        let src = ns.string

        // Attribute values (before attr names so names can overwrite the = sign)
        paint(pattern: #""[^"]*"|'[^']*'"#,
              color: .systemOrange, in: ns, source: src)

        // Attribute names (word before `=`)
        paint(pattern: #"\b([\w:.-]+)\s*="#,
              color: .systemTeal, in: ns, source: src, captureGroup: 1)

        // Tag names (`<word` or `</word` or `<word/`)
        paint(pattern: #"</?([A-Za-z][\w:.-]*)"#,
              color: .systemBlue, in: ns, source: src, captureGroup: 1)

        // Comments (overwrite anything inside <!--…-->)
        paint(pattern: #"<!--[\s\S]*?-->"#,
              color: .secondaryLabelColor, in: ns, source: src,
              options: [.dotMatchesLineSeparators])

        // CDATA
        paint(pattern: #"<!\[CDATA\[[\s\S]*?\]\]>"#,
              color: .secondaryLabelColor, in: ns, source: src,
              options: [.dotMatchesLineSeparators])
    }

    // MARK: - YAML

    private static func applyYAML(to ns: NSMutableAttributedString) {
        let src = ns.string

        // Numbers
        paint(pattern: #"-?\b\d+(\.\d+)?([eE][+-]?\d+)?\b"#,
              color: .systemPurple, in: ns, source: src)

        // Keywords (YAML-specific booleans)
        paint(pattern: #"\b(true|false|null|yes|no|on|off|~)\b"#,
              color: .systemRed, in: ns, source: src)

        // Quoted strings
        paint(pattern: #""(?:[^"\\]|\\.)*"|'[^']*'"#,
              color: .systemOrange, in: ns, source: src)

        // Mapping keys: text before `:` at start of a content line
        paint(pattern: #"^(\s*[\w. -]+)\s*:"#,
              color: .systemBlue, in: ns, source: src,
              captureGroup: 1,
              options: [.anchorsMatchLines])

        // Block sequence dashes
        paint(pattern: #"^\s*-(?=\s)"#,
              color: .secondaryLabelColor, in: ns, source: src,
              options: [.anchorsMatchLines])

        // Comments (highest priority — overwrite everything)
        paint(pattern: #"#[^\n]*"#,
              color: NSColor.systemGreen.withAlphaComponent(0.8),
              in: ns, source: src)
    }

    // MARK: - CSV

    private static func applyCSV(to ns: NSMutableAttributedString) {
        let src    = ns.string
        let nsStr  = src as NSString

        // Header row (first line) → bold blue
        let firstNewline = nsStr.range(of: "\n")
        let headerEnd    = firstNewline.location != NSNotFound
            ? firstNewline.location
            : nsStr.length
        if headerEnd > 0 {
            let headerRange = NSRange(location: 0, length: headerEnd)
            let boldMono    = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
            ns.addAttribute(.font,            value: boldMono,           range: headerRange)
            ns.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: headerRange)
        }

        // Numbers in data rows
        paint(pattern: #"(?<=,|\t|^)\s*-?\d+(\.\d+)?\s*(?=,|\t|$)"#,
              color: .systemPurple, in: ns, source: src,
              options: [.anchorsMatchLines])
    }

    // MARK: - Generic regex painter

    private static func paint(
        pattern:      String,
        color:        NSColor,
        in ns:        NSMutableAttributedString,
        source:       String,
        captureGroup: Int = 0,
        options:      NSRegularExpression.Options = []
    ) {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        rx.enumerateMatches(in: source, options: [], range: fullRange) { m, _, _ in
            guard let m else { return }
            let r = m.range(at: captureGroup)
            guard r.location != NSNotFound else { return }
            ns.addAttribute(.foregroundColor, value: color, range: r)
        }
    }
}
