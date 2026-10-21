import Foundation

// MARK: - CSVDocumentSerializer

/// Serializes a tabular `NodeIndex` to RFC 4180 CSV bytes.
///
/// The document **must** satisfy `NodeIndex.isTabular()` — that is, the root
/// must be an array of uniform objects sharing the same ordered key set.  Any
/// other shape throws `CSVSerializerError.notTabular`.
///
/// **Output format:**
/// - Header row: every key used by any row, in order of first appearance.
/// - One data row per root-level child.
/// - Fields are quoted with double-quotes when they contain the delimiter,
///   double-quote, newline, or carriage-return characters.
/// - Interior double-quotes are escaped by doubling (`"` → `""`).
/// - Lines are separated by `\n` (LF).
public struct CSVDocumentSerializer {

    private let index: NodeIndex

    public init(index: NodeIndex) {
        self.index = index
    }

    // MARK: - Public API

    /// Serialize the document to CSV bytes.
    ///
    /// - Parameter delimiter: Field delimiter character (default `,`).
    public func serialize(delimiter: Character = ",") throws -> Data {
        guard index.isTabular() else {
            throw CSVSerializerError.notTabular
        }
        guard let root = index.root else {
            throw CSVSerializerError.emptyDocument
        }

        let rowNodes = index.children(of: root.id)
        let columns = allColumns(of: rowNodes)
        var lines: [String] = []

        // Header row
        lines.append(row(cells: columns, delimiter: delimiter))

        // Data rows
        for rowNode in rowNodes {
            lines.append(row(cells: cells(of: rowNode, columns: columns), delimiter: delimiter))
        }

        let text = lines.joined(separator: "\n") + "\n"
        return Data(text.utf8)
    }

    /// Serialize a document that was opened from a CSV file, for saving it
    /// back to that file (#39).
    ///
    /// Unlike `serialize(delimiter:)`, which exports any uniform array of
    /// objects, this writes the file's own layout as recorded by `CSVParser`:
    /// its delimiter, and no header row when the file had none. Rows need not
    /// share a key set; a row missing a column gets an empty cell.
    public func serializeInSourceLayout() throws -> Data {
        guard let root = index.root else {
            throw CSVSerializerError.emptyDocument
        }
        guard root.type == .array else {
            throw CSVSerializerError.notTabular
        }
        var delimiter: Character = ","
        if case .csv(let meta) = root.metadata {
            delimiter = meta.delimiter
        }

        let rowNodes = index.children(of: root.id)
        var lines: [String] = []

        if rowNodes.allSatisfy({ $0.type == .array }) {
            // No header: each row is a positional array of scalars.
            for rowNode in rowNodes {
                let cells = index.children(of: rowNode.id).map(cellText)
                lines.append(row(cells: cells, delimiter: delimiter))
            }
        } else if rowNodes.allSatisfy({ $0.type == .object }) {
            let columns = allColumns(of: rowNodes)
            lines.append(row(cells: columns, delimiter: delimiter))
            for rowNode in rowNodes {
                lines.append(row(cells: cells(of: rowNode, columns: columns), delimiter: delimiter))
            }
        } else {
            throw CSVSerializerError.notTabular
        }

        let text = lines.map { $0 + "\n" }.joined()
        return Data(text.utf8)
    }

    // MARK: - Private helpers

    /// Every key used by any row, in order of first appearance.
    ///
    /// `isTabular()` only samples the leading rows, so a later row can carry
    /// keys the first row lacks — e.g. surplus fields of a ragged CSV (#28).
    /// Taking columns from the first row alone would drop them on export.
    private func allColumns(of rowNodes: [DocumentNode]) -> [String] {
        var columns: [String] = []
        var seen = Set<String>()
        for rowNode in rowNodes {
            for kv in index.children(of: rowNode.id) {
                if let key = kv.key, seen.insert(key).inserted { columns.append(key) }
            }
        }
        return columns
    }

    /// Cell text of an object row for each column, empty where the row lacks it.
    private func cells(of rowNode: DocumentNode, columns: [String]) -> [String] {
        let kvs = index.children(of: rowNode.id)
        return columns.map { col -> String in
            guard let kv = kvs.first(where: { $0.key == col }),
                  let scalar = index.children(of: kv.id).first
            else { return "" }
            return cellText(scalar)
        }
    }

    private func row(cells: [String], delimiter: Character) -> String {
        cells.map { quote($0, delimiter: delimiter) }.joined(separator: String(delimiter))
    }

    /// Extract the display text for a scalar node (without the surrounding quotes
    /// used by `ScalarValue.displayText`).
    private func cellText(_ node: DocumentNode) -> String {
        switch node.value {
        case .scalar(let sv):
            switch sv {
            case .string(let s):  return s
            case .integer(let i): return String(i)
            case .float(let f):   return csvDouble(f)
            case .boolean(let b): return b ? "true" : "false"
            case .null:           return ""
            }
        case .unparsed:
            return ""
        case .container, .error:
            return ""
        }
    }

    /// RFC 4180 quoting: wrap in double-quotes if the field contains the
    /// delimiter, a double-quote, LF, or CR.  Interior double-quotes are escaped
    /// by doubling.
    private func quote(_ s: String, delimiter: Character) -> String {
        let needsQuoting = s.contains(delimiter)
                        || s.contains("\"")
                        || s.contains("\n")
                        || s.contains("\r")
        guard needsQuoting else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func csvDouble(_ value: Double) -> String {
        if value.isNaN      { return "" }
        if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int64(value))
        }
        return String(value)
    }
}

// MARK: - Errors

public enum CSVSerializerError: Error, Sendable {
    /// The document is not a uniform array of objects and cannot be expressed as CSV.
    case notTabular
    /// The NodeIndex contains no root node.
    case emptyDocument
}
