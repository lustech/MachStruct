import Foundation

// MARK: - FormatDetector

/// Content-based format sniffer for `MappedFile` and raw byte headers.
///
/// **Detection order** (highest-confidence first):
/// 1. BOM stripping (UTF-8/16/32)
/// 2. First non-whitespace byte: `{` / `[` → JSON,  `<` → XML
/// 3. First non-empty line: `---` / `%YAML` / `%TAG` → YAML
/// 4. Delimiter consistency score across first 5 lines → CSV
/// 5. YAML structural heuristic (`key: value` / `- item` patterns)
/// 6. File-extension fallback
/// 7. Default → JSON
///
/// The whole probe reads at most 512 bytes so it is always O(1).
public struct FormatDetector: Sendable {

    // MARK: - Result type

    public enum DetectedFormat: String, Sendable, Equatable, CaseIterable {
        case json
        case xml
        case yaml
        case csv
        case unknown
    }

    // MARK: - Public API

    /// Sniff `file`, optionally biased by `fileExtension`.
    public static func detect(
        file: MappedFile,
        fileExtension: String? = nil
    ) -> DetectedFormat {
        let probeLength = UInt32(min(UInt64(512), file.fileSize))
        guard let header = try? file.data(offset: 0, length: probeLength) else {
            return extensionFallback(fileExtension)
        }
        return detect(headerBytes: header, fileExtension: fileExtension)
    }

    /// Sniff raw bytes, optionally biased by `fileExtension`.
    ///
    /// This overload is used by tests and callers that have a `Data` header
    /// but not yet a full `MappedFile`.
    public static func detect(
        headerBytes: Data,
        fileExtension: String? = nil
    ) -> DetectedFormat {
        var bytes = headerBytes

        // ── 1. BOM stripping ─────────────────────────────────────────────────
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes = bytes.dropFirst(3)  // UTF-8 BOM
        } else if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00])
               || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return extensionFallback(fileExtension)  // UTF-32 — can't probe directly
        } else if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            return extensionFallback(fileExtension)  // UTF-16 — can't probe directly
        }

        // ── 2. First non-whitespace byte ─────────────────────────────────────
        let wsBytes: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]  // SP, TAB, LF, CR
        if let first = bytes.first(where: { !wsBytes.contains($0) }) {
            if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") { return .json }
            if first == UInt8(ascii: "<") { return .xml }
        } else {
            return extensionFallback(fileExtension)  // all whitespace
        }

        // Work in UTF-8 text from here on
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            return extensionFallback(fileExtension)
        }

        // ── 3. Explicit YAML document markers ────────────────────────────────
        let firstNonEmpty = text.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        let trimmed = firstNonEmpty.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("---")   { return .yaml }
        if trimmed.hasPrefix("%YAML") { return .yaml }
        if trimmed.hasPrefix("%TAG")  { return .yaml }

        // ── 4. CSV delimiter consistency ──────────────────────────────────────
        let csvResult = probeCSV(text)
        let yamlScore = probeYAML(text)

        if let (_, csvConf) = csvResult, csvConf > yamlScore {
            return .csv
        }

        // ── 5. YAML structural heuristic ─────────────────────────────────────
        if yamlScore >= 4 {
            return .yaml
        }

        // ── 6. Extension fallback ─────────────────────────────────────────────
        let byExt = extensionFallback(fileExtension)
        if byExt != .unknown { return byExt }

        // ── 7. Default ────────────────────────────────────────────────────────
        return .json
    }

    // MARK: - Delimiter consistency probe

    /// Score the first few lines for CSV-ness.
    ///
    /// Returns `(delimiter, confidence)` where confidence is the number of
    /// fields per row (higher = more confident) if at least 2 lines have the
    /// same positive delimiter count; otherwise `nil`.
    private static func probeCSV(_ text: String) -> (Character, Int)? {
        let candidates: [Character] = [",", "\t", ";", "|"]
        let lines = text.components(separatedBy: .newlines)
            .map    { $0.trimmingCharacters(in: .init(charactersIn: "\r")) }
            .filter { !$0.isEmpty }
            .prefix(6)

        guard lines.count >= 2 else { return nil }

        var bestDelim: Character = ","
        var bestConf  = 0

        for delim in candidates {
            let counts = lines.map { countDelimiters($0, delimiter: delim) }
            guard let first = counts.first, first > 0 else { continue }
            // Allow one line to differ by 1 (last row may have fewer fields)
            let closeEnough = counts.dropFirst().allSatisfy { abs($0 - first) <= 1 }
            guard closeEnough else { continue }
            // Confidence = fields per row; prefer higher field count
            let conf = first + 1   // fields = delimiters + 1
            if conf > bestConf {
                bestConf  = conf
                bestDelim = delim
            }
        }

        return bestConf >= 2 ? (bestDelim, bestConf) : nil  // require ≥ 2 fields
    }

    /// Count delimiter characters in a line, respecting RFC 4180 double-quotes.
    private static func countDelimiters(_ line: String, delimiter: Character) -> Int {
        var count   = 0
        var inQuote = false
        for ch in line {
            if ch == "\"" { inQuote.toggle(); continue }
            if !inQuote && ch == delimiter { count += 1 }
        }
        return count
    }

    // MARK: - YAML structural heuristic

    /// Returns a confidence score [0–10] for the text looking like YAML.
    ///
    /// - `mapping key: value` on first content line → 8
    /// - `- item` on first content line → 7
    /// - `trailing colon` (bare key) → 5
    /// - Score 0 if the first char is a digit or `"` (likely non-YAML scalar)
    private static func probeYAML(_ text: String) -> Int {
        let lines = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(3)

        guard let first = lines.first else { return 0 }
        let trimmed = first.trimmingCharacters(in: .whitespaces)

        // Starts with digit or quote → likely not YAML mapping/sequence
        if let c = trimmed.first, c.isNumber || c == "\"" { return 0 }

        if trimmed.hasPrefix("- ")  { return 7 }   // block sequence
        if trimmed.contains(": ")   { return 8 }   // mapping
        if trimmed.hasSuffix(":")   { return 5 }   // bare mapping key

        return 0
    }

    // MARK: - Extension fallback

    private static func extensionFallback(_ ext: String?) -> DetectedFormat {
        switch ext?.lowercased() {
        case "json":         return .json
        case "xml":          return .xml
        case "yaml", "yml":  return .yaml
        case "csv", "tsv":   return .csv
        default:             return .unknown
        }
    }
}
