import Foundation

// MARK: - CSVDocumentSerializer

/// Serializes a tabular `NodeIndex` to RFC 4180 CSV bytes.
///
/// The document **must** satisfy `NodeIndex.isTabular()` — that is, the root
/// must be an array of uniform objects sharing the same ordered key set.  Any
/// other shape throws `CSVSerializerError.notTabular`.
///
/// **Output format:**
/// - Header row derived from `NodeIndex.tabularColumns`.
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

        let columns = index.tabularColumns
        var lines: [String] = []

        // Header row
        lines.append(row(cells: columns, delimiter: delimiter))

        // Data rows
        for rowNode in index.children(of: root.id) {
            let kvs = index.children(of: rowNode.id)
            let cells = columns.map { col -> String in
                guard let kv = kvs.first(where: { $0.key == col }),
                      let scalar = index.children(of: kv.id).first
                else { return "" }
                return cellText(scalar)
            }
            lines.append(row(cells: cells, delimiter: delimiter))
        }

        let text = lines.joined(separator: "\n") + "\n"
        return Data(text.utf8)
    }

    // MARK: - Private helpers

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
