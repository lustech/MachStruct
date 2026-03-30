import Foundation

// MARK: - CSVParser

/// RFC 4180-compliant CSV/TSV parser with auto-delimiter and header detection.
///
/// ## Tree shape
/// **With header row** (most CSVs):
/// ```
/// .array  (root — all data rows)
///   .object  (one per data row — keyed by column name)
///     .keyValue "colName"
///       .scalar  (cell value)
/// ```
///
/// **Without header row:**
/// ```
/// .array  (root)
///   .array  (one per row)
///     .scalar  (cell, key = "0", "1", …)
/// ```
///
/// ## Auto-delimiter detection
/// Samples the first 8 KB and scores `,` `;` `\t` `|` by counting consistent
/// occurrences per line while respecting quoted fields.
///
/// ## Auto-header detection
/// If every cell in the first row is a pure string (not parseable as integer,
/// float, boolean, or null), the row is treated as a header.
public actor CSVParser: StructParser {

    public static let supportedExtensions: Set<String> = ["csv", "tsv"]

    public init() {}

    // MARK: - Phase 1

    public func buildIndex(from file: MappedFile) async throws -> StructuralIndex {
        guard file.fileSize > 0 else {
            let entry = IndexEntry(id: .generate(), nodeType: .array, depth: 0, parentID: nil)
            return StructuralIndex(entries: [entry])
        }

        let text = try loadText(from: file)
        return buildEntries(from: text)
    }

    // MARK: - Progressive streaming

    public nonisolated func parseProgressively(file: MappedFile) -> AsyncStream<ParseProgress> {
        AsyncStream { continuation in
            Task {
                do {
                    let parser = CSVParser()
                    let index = try await parser.buildIndex(from: file)
                    let batchSize = 1_000
                    var batch: [IndexEntry] = []
                    batch.reserveCapacity(batchSize)
                    for entry in index.entries {
                        batch.append(entry)
                        if batch.count == batchSize {
                            continuation.yield(.nodesIndexed(batch))
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                    if !batch.isEmpty { continuation.yield(.nodesIndexed(batch)) }
                    continuation.yield(.complete(index))
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Phase 2

    public nonisolated func parseValue(entry: IndexEntry, from file: MappedFile) throws -> NodeValue {
        if let sv = entry.parsedValue { return .scalar(sv) }
        switch entry.nodeType {
        case .object: return .container(childCount: Int(entry.childCount))
        case .array:  return .container(childCount: Int(entry.childCount))
        case .keyValue, .scalar: return .unparsed
        }
    }

    // MARK: - Serialize

    /// Produces a correctly-quoted CSV cell string for the given scalar value.
    public nonisolated func serialize(value: NodeValue) throws -> Data {
        switch value {
        case .scalar(let sv):
            return Data(csvCell(for: sv).utf8)
        case .container:
            throw CSVParserError.cannotSerializeContainer
        case .unparsed, .error:
            throw CSVParserError.noValueToSerialize
        }
    }

    // MARK: - Validate

    /// Reports rows whose column count differs from the first row.
    public func validate(file: MappedFile) async throws -> [ValidationIssue] {
        guard file.fileSize > 0 else { return [] }
        let text = try loadText(from: file)
        let delimiter = detectDelimiter(in: text)
        let rows = parseRows(text: text, delimiter: delimiter)
        guard rows.count > 1 else { return [] }

        let expected = rows[0].count
        var issues: [ValidationIssue] = []
        for (i, row) in rows.enumerated() where row.count != expected {
            issues.append(ValidationIssue(
                severity: .warning,
                message: "Row \(i + 1) has \(row.count) column\(row.count == 1 ? "" : "s"); expected \(expected)"
            ))
        }
        return issues
    }
}

// MARK: - Core build logic

private extension CSVParser {

    nonisolated func loadText(from file: MappedFile) throws -> String {
        let length = UInt32(min(file.fileSize, UInt64(UInt32.max)))
        let data = try file.data(offset: 0, length: length)
        // Try UTF-8 first; fall back to Latin-1 for legacy files.
        guard let text = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .isoLatin1) else {
            throw CSVParserError.encodingError
        }
        return text
    }

    nonisolated func buildEntries(from text: String) -> StructuralIndex {
        let delimiter = detectDelimiter(in: text)
        let allRows   = parseRows(text: text, delimiter: delimiter)

        guard !allRows.isEmpty else {
            let entry = IndexEntry(id: .generate(), nodeType: .array, depth: 0, parentID: nil)
            return StructuralIndex(entries: [entry])
        }

        let hasHeader = detectHasHeader(rows: allRows)
        let headers: [String]
        let dataRows: [[String]]

        if hasHeader && allRows.count > 1 {
            headers  = allRows[0]
            dataRows = Array(allRows.dropFirst())
        } else {
            // No header: generate positional column names "0", "1", …
            headers  = (0 ..< (allRows[0].count)).map { String($0) }
            dataRows = allRows
        }

        let colCount = headers.count
        // Pre-compute capacity: root + Σ(row + colCount × cells_per_col)
        let cellsPerRow = hasHeader ? 1 + colCount * 2 : 1 + colCount
        var entries = [IndexEntry]()
        entries.reserveCapacity(1 + dataRows.count * cellsPerRow)

        // Root
        let rootID   = NodeID.generate()
        let rootMeta = CSVMetadata(delimiter: delimiter, hasHeader: hasHeader, columnIndex: 0)
        entries.append(IndexEntry(
            id: rootID, nodeType: .array, depth: 0, parentID: nil,
            childCount: UInt32(dataRows.count),
            metadata: .csv(rootMeta)
        ))

        for row in dataRows {
            let rowID   = NodeID.generate()
            let usedCols = min(row.count, colCount)

            if hasHeader {
                // Represent each data row as an object keyed by column name.
                entries.append(IndexEntry(
                    id: rowID, nodeType: .object, depth: 1, parentID: rootID,
                    childCount: UInt32(usedCols)
                ))
                for colIdx in 0 ..< usedCols {
                    let kvID  = NodeID.generate()
                    let sID   = NodeID.generate()
                    let cell  = row[colIdx]
                    let meta  = CSVMetadata(delimiter: delimiter, hasHeader: true, columnIndex: colIdx)
                    entries.append(IndexEntry(
                        id: kvID, nodeType: .keyValue, depth: 2, parentID: rowID,
                        childCount: 1, key: headers[colIdx]
                    ))
                    entries.append(IndexEntry(
                        id: sID, nodeType: .scalar, depth: 3, parentID: kvID,
                        parsedValue: parseScalarValue(cell),
                        metadata: .csv(meta)
                    ))
                }
            } else {
                // No header: represent each row as a positional array.
                entries.append(IndexEntry(
                    id: rowID, nodeType: .array, depth: 1, parentID: rootID,
                    childCount: UInt32(row.count)
                ))
                for (colIdx, cell) in row.enumerated() {
                    let sID  = NodeID.generate()
                    let meta = CSVMetadata(delimiter: delimiter, hasHeader: false, columnIndex: colIdx)
                    entries.append(IndexEntry(
                        id: sID, nodeType: .scalar, depth: 2, parentID: rowID,
                        key: String(colIdx),
                        parsedValue: parseScalarValue(cell),
                        metadata: .csv(meta)
                    ))
                }
            }
        }

        return StructuralIndex(entries: entries)
    }
}

// MARK: - RFC 4180 tokenizer

private extension CSVParser {

    /// Parse all rows from `text` using the given `delimiter`.
    /// Handles quoted fields (including embedded delimiters and newlines),
    /// `""` escape sequences, and both `\n` / `\r\n` line endings.
    nonisolated func parseRows(text: String, delimiter: Character) -> [[String]] {
        var tokenizer = CSVTokenizer(text: text, delimiter: delimiter)
        var rows: [[String]] = []
        while let row = tokenizer.nextRow() {
            // Skip blank sentinel rows (trailing newline produces [""])
            if row.count == 1 && row[0].isEmpty { continue }
            rows.append(row)
        }
        return rows
    }
}

/// Character-level RFC 4180 scanner.
private struct CSVTokenizer {
    let text: String
    var pos: String.Index
    let delimiter: Character

    init(text: String, delimiter: Character) {
        self.text      = text
        self.pos       = text.startIndex
        self.delimiter = delimiter
    }

    /// Returns the next row's fields, or `nil` at end-of-input.
    mutating func nextRow() -> [String]? {
        guard pos < text.endIndex else { return nil }
        var fields: [String] = []
        while true {
            fields.append(nextField())
            guard pos < text.endIndex else { break }
            if text[pos] == delimiter {
                pos = text.index(after: pos)   // consume delimiter → more fields
            } else {
                consumeLineEnding()             // \n or \r\n → end of row
                break
            }
        }
        return fields
    }

    private mutating func nextField() -> String {
        guard pos < text.endIndex else { return "" }
        return text[pos] == "\"" ? quotedField() : unquotedField()
    }

    private mutating func unquotedField() -> String {
        let start = pos
        while pos < text.endIndex {
            let c = text[pos]
            // Swift treats \r\n as a single Character (grapheme cluster).
            // Check for all three possible line-ending representations.
            if c == delimiter || c == "\n" || c == "\r" || c == "\r\n" { break }
            pos = text.index(after: pos)
        }
        return String(text[start ..< pos])
    }

    private mutating func quotedField() -> String {
        pos = text.index(after: pos)    // skip opening "
        var result = ""
        while pos < text.endIndex {
            if text[pos] == "\"" {
                pos = text.index(after: pos)
                if pos < text.endIndex && text[pos] == "\"" {
                    result.append("\"")         // "" → literal "
                    pos = text.index(after: pos)
                } else {
                    break                       // closing "
                }
            } else {
                result.append(text[pos])
                pos = text.index(after: pos)
            }
        }
        return result
    }

    private mutating func consumeLineEnding() {
        guard pos < text.endIndex else { return }
        let c = text[pos]
        // \r\n is a single grapheme cluster in Swift — advance once for all three forms.
        if c == "\r\n" || c == "\n" || c == "\r" {
            pos = text.index(after: pos)
        }
    }
}

// MARK: - Delimiter detection

private extension CSVParser {

    /// Scores `,` `;` `\t` `|` on a sample of the first 8 KB.
    ///
    /// Scoring: for each candidate delimiter, count occurrences per line
    /// (ignoring characters inside quoted fields), then reward high average
    /// counts and penalise inconsistent counts across lines.
    nonisolated func detectDelimiter(in text: String) -> Character {
        let sample = String(text.prefix(8_192))
        let lines  = sample.components(separatedBy: "\n").prefix(20).filter { !$0.isEmpty }
        guard lines.count >= 2 else { return "," }

        let candidates: [Character] = [",", ";", "\t", "|"]
        var bestChar  : Character   = ","
        var bestScore : Double      = -1

        for delim in candidates {
            let counts: [Double] = lines.map { line in
                var inQuote = false
                var n       = 0
                for ch in line {
                    if ch == "\"" { inQuote.toggle() }
                    else if !inQuote && ch == delim { n += 1 }
                }
                return Double(n)
            }
            guard let firstCount = counts.first, firstCount > 0 else { continue }
            let avg      = counts.reduce(0, +) / Double(counts.count)
            let variance = counts.reduce(0) { $0 + ($1 - avg) * ($1 - avg) } / Double(counts.count)
            let score    = avg / (1 + variance)
            if score > bestScore { bestScore = score; bestChar = delim }
        }

        return bestChar
    }
}

// MARK: - Header detection

private extension CSVParser {

    /// Returns `true` when every cell in the first row is a pure string
    /// (not parseable as integer, float, boolean, or null).
    ///
    /// This heuristic correctly handles the common case where header rows
    /// contain column names like "name", "age", "created_at".  Numeric
    /// column names (e.g. "1", "2") will cause the first row to be treated
    /// as data, which is the safer interpretation.
    nonisolated func detectHasHeader(rows: [[String]]) -> Bool {
        guard rows.count >= 2 else { return false }
        return rows[0].allSatisfy { cell in
            guard !cell.isEmpty else { return true }
            if case .string = parseScalarValue(cell) { return true }
            return false
        }
    }
}

// MARK: - Serialization helpers

private extension CSVParser {

    nonisolated func csvCell(for sv: ScalarValue, delimiter: Character = ",") -> String {
        let raw: String
        switch sv {
        case .string(let s):  raw = s
        case .integer(let n): raw = "\(n)"
        case .float(let f):   raw = "\(f)"
        case .boolean(let b): raw = b ? "true" : "false"
        case .null:           raw = ""
        }
        // Quote when the value contains the delimiter, a quote, or a line break.
        if raw.contains(delimiter) || raw.contains("\"")
            || raw.contains("\n")  || raw.contains("\r") {
            return "\"\(raw.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return raw
    }
}

// MARK: - Errors

public enum CSVParserError: Error, Sendable {
    case encodingError
    case cannotSerializeContainer
    case noValueToSerialize
}
