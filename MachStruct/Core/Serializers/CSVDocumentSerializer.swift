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
    private let source: (any DocumentSource)?

    /// - Parameter source: where to build what `index` lacks: a large file's
    ///   index holds only what has been expanded and edited. Rows are then
    ///   built one at a time as they are written, not all held at once.
    public init(index: NodeIndex, source: (any DocumentSource)? = nil) {
        self.index = index
        self.source = source
    }

    // MARK: - Public API

    /// Serialize the document to CSV bytes.
    ///
    /// - Parameter delimiter: Field delimiter character (default `,`).
    public func serialize(delimiter: Character = ",") throws -> Data {
        var text = ""
        try write(to: &text, delimiter: delimiter)
        return Data(text.utf8)
    }

    /// `serialize(delimiter:)` into `text`, such as a `FileTextStream` for a
    /// large document, whose text is then never held whole.
    public func write<Out: TextOutputStream>(to text: inout Out, delimiter: Character = ",") throws {
        guard let root = index.root, isTabular(root) else {
            throw CSVSerializerError.notTabular
        }

        let columns = allColumns(under: root)

        // Header row
        appendRow(columns, delimiter: delimiter, to: &text)

        // Data rows
        for rowNode in children(of: root) {
            appendRow(cells(of: rowNode, columns: columns), delimiter: delimiter, to: &text)
        }
    }

    /// Serialize a document that was opened from a CSV file, for saving it
    /// back to that file (#39).
    ///
    /// Unlike `serialize(delimiter:)`, which exports any uniform array of
    /// objects, this writes the file's own layout as recorded by `CSVParser`:
    /// its delimiter, and no header row when the file had none. Rows need not
    /// share a key set; a row missing a column gets an empty cell.
    public func serializeInSourceLayout() throws -> Data {
        var text = ""
        try writeInSourceLayout(to: &text)
        return Data(text.utf8)
    }

    /// `serializeInSourceLayout()` into `text`, such as a `FileTextStream`
    /// for a large document, whose text is then never held whole.
    public func writeInSourceLayout<Out: TextOutputStream>(to text: inout Out) throws {
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

        // One pass for the layout and the columns, one to write: a large
        // file's rows are built from its source on each.
        var allArrays = true
        var allObjects = true
        var columns = Columns()
        for rowNode in children(of: root) {
            allArrays = allArrays && rowNode.type == .array
            allObjects = allObjects && rowNode.type == .object
            if !allArrays && !allObjects { throw CSVSerializerError.notTabular }
            if allObjects { columns.add(keysOf: rowNode, from: self) }
        }

        if allArrays {
            // No header: each row is a positional array of scalars.
            for rowNode in children(of: root) {
                appendRow(children(of: rowNode).map(cellText), delimiter: delimiter, to: &text)
            }
        } else {
            let columns = columns.names
            appendRow(columns, delimiter: delimiter, to: &text)
            for rowNode in children(of: root) {
                appendRow(cells(of: rowNode, columns: columns), delimiter: delimiter, to: &text)
            }
        }
    }

    // MARK: - Private helpers

    private func children(of node: DocumentNode) -> OverlaidChildren {
        index.children(of: node, source: source)
    }

    /// `NodeIndex.isTabular()`, reading rows the index lacks from the source.
    private func isTabular(_ root: DocumentNode, sampleSize: Int = 10) -> Bool {
        guard source != nil else { return index.isTabular(sampleSize: sampleSize) }
        guard root.type == .array else { return false }
        let sample = Array(children(of: root).prefix(sampleSize))
        guard !sample.isEmpty,
              sample.allSatisfy({ $0.type == .object }) else { return false }
        let firstKeys = children(of: sample[0]).compactMap { $0.key }
        guard !firstKeys.isEmpty else { return false }
        return sample.allSatisfy { row in
            children(of: row).compactMap { $0.key } == firstKeys
        }
    }

    /// Every key used by any row, in order of first appearance.
    ///
    /// `isTabular()` only samples the leading rows, so a later row can carry
    /// keys the first row lacks — e.g. surplus fields of a ragged CSV (#28).
    /// Taking columns from the first row alone would drop them on export.
    private func allColumns(under root: DocumentNode) -> [String] {
        var columns = Columns()
        for rowNode in children(of: root) { columns.add(keysOf: rowNode, from: self) }
        return columns.names
    }

    private struct Columns {
        private(set) var names: [String] = []
        private var seen = Set<String>()

        mutating func add(keysOf rowNode: DocumentNode, from serializer: CSVDocumentSerializer) {
            for kv in serializer.children(of: rowNode) {
                if let key = kv.key, seen.insert(key).inserted { names.append(key) }
            }
        }
    }

    /// Cell text of an object row for each column, empty where the row lacks it.
    private func cells(of rowNode: DocumentNode, columns: [String]) -> [String] {
        let kvs = Array(children(of: rowNode))
        // A row usually has the columns in order; while it does, its member
        // at a column's position is the first with that key.
        var inOrder = true
        return columns.indices.map { i -> String in
            let col = columns[i]
            inOrder = inOrder && i < kvs.count && kvs[i].key == col
            guard let kv = inOrder ? kvs[i] : kvs.first(where: { $0.key == col }),
                  let scalar = children(of: kv).first
            else { return "" }
            return cellText(scalar)
        }
    }

    private func appendRow<Out: TextOutputStream>(_ cells: [String], delimiter: Character,
                                                  to text: inout Out) {
        text.write(row(cells: cells, delimiter: delimiter))
        text.write("\n")
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
        guard needsQuoting(s, delimiter: delimiter) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Whether `s` holds the delimiter, a double-quote, LF or CR. Checked on
    /// its bytes: comparing Characters misses a CRLF, which is one Character,
    /// and a delimiter joined to a combining mark, leaving the field unquoted
    /// and split in two when read back (#75).
    private func needsQuoting(_ s: String, delimiter: Character) -> Bool {
        guard let d = delimiter.asciiValue else {
            return s.contains(delimiter) || s.utf8.contains { $0 == 0x22 || $0 == 0x0A || $0 == 0x0D }
        }
        return s.utf8.contains { $0 == d || $0 == 0x22 || $0 == 0x0A || $0 == 0x0D }
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
