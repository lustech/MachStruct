import Foundation
import CSimdjsonBridge

// MARK: - CSVSource

/// A large CSV file read straight from its bytes (ADR-002).
///
/// Opening scans the file once and keeps only where each row starts; a row's
/// cells are read from its bytes when it is shown. The tree has the same
/// shape `CSVParser` builds: an array of rows, each an object keyed by the
/// header (or an array, without one), each cell a key with a scalar value.
///
/// A node's ID encodes where it starts: `base + 4 × offset + kind`, where
/// `kind` is 0 for a row, 1 for a cell's key, 2 for a cell's value and 3 for
/// the root.
public final class CSVSource: DocumentSource, @unchecked Sendable {

    public let file: MappedFile
    public let rootID: NodeID
    public let nodeCount: Int

    private let base: UInt64
    private let delimiter: UInt8
    private let hasHeader: Bool
    private let isUTF8: Bool
    /// Where each data row starts (the header row, if any, is not one).
    private let rowOffsets: [UInt64]
    /// The key of each column: the header, then `column_N` for fields past
    /// its end. Without a header, positional names.
    private let keys: [String]
    /// The metadata of each column's cells, shared between them.
    private let columnMetadata: [FormatMetadata]
    private let rootMetadata: FormatMetadata

    private enum Kind: UInt64 {
        case row = 0
        case key = 1
        case value = 2
        case root = 3
    }

    public init(file: MappedFile) {
        self.file = file
        base = NodeID.reserveBlock(count: Int(4 * (file.fileSize + 1)))
        rootID = NodeID(rawValue: base + Kind.root.rawValue)
        let bytes = file.rawPointer.assumingMemoryBound(to: CChar.self)

        // The delimiter is detected from the start of the file, as CSVParser does.
        let parser = CSVParser()
        let sample = UnsafeRawBufferPointer(start: file.rawPointer,
                                            count: Int(min(file.fileSize, 8_192)))
        let sampleText = String(bytes: sample, encoding: .utf8)
            ?? String(decoding: sample, as: UTF8.self)
        let delimiterCharacter = parser.detectDelimiter(in: sampleText)
        let delim = delimiterCharacter.asciiValue ?? UInt8(ascii: ",")
        delimiter = delim

        var info = MSCSVInfo()
        ms_csv_scan(bytes, file.fileSize, CChar(bitPattern: delim), nil, 0, &info)
        let utf8 = info.is_utf8 == 1
        // Decoding as UTF-8 drops a byte order mark, so CSVParser never sees one.
        let hasBOM = utf8 && file.fileSize >= 3
            && UnsafeRawBufferPointer(start: file.rawPointer, count: 3).elementsEqual([0xEF, 0xBB, 0xBF])
        let skip: UInt64 = hasBOM ? 3 : 0
        if hasBOM {
            ms_csv_scan(bytes + 3, file.fileSize - 3, CChar(bitPattern: delim), nil, 0, &info)
        }
        var rows = [UInt64](repeating: 0, count: Int(info.rows))
        if !rows.isEmpty {
            ms_csv_scan(bytes + Int(skip), file.fileSize - skip, CChar(bitPattern: delim),
                        &rows, info.rows, &info)
            if skip > 0 { rows = rows.map { $0 + skip } }
        }
        isUTF8 = utf8

        // The header is detected from the first row, as CSVParser does.
        let firstRow = rows.first.map { Self.fields(ofRowAt: $0, in: file, delimiter: delim) } ?? []
        let firstTexts: [String] = firstRow.map { Self.text(of: $0, in: file, utf8: utf8) }
        let header = rows.count >= 2
            && parser.detectHasHeader(rows: [firstTexts, []])
        hasHeader = header

        let widest = Int(info.widest)
        if header {
            var names = firstTexts
            if widest > names.count {
                names += parser.synthesisedKeys(for: names.count ..< widest, avoiding: names)
            }
            keys = names
            rowOffsets = Array(rows.dropFirst())
            let cells = Int(info.fields) - firstTexts.count
            nodeCount = 1 + rowOffsets.count + 2 * cells
        } else {
            keys = (0 ..< widest).map(String.init)
            rowOffsets = rows
            nodeCount = 1 + rows.count + Int(info.fields)
        }
        columnMetadata = (0 ..< max(widest, 1)).map {
            .csv(CSVMetadata(delimiter: delimiterCharacter, hasHeader: header, columnIndex: $0))
        }
        rootMetadata = .csv(CSVMetadata(delimiter: delimiterCharacter, hasHeader: header,
                                        columnIndex: 0))
    }

    // MARK: IDs

    private func id(_ offset: UInt64, _ kind: Kind) -> NodeID {
        NodeID(rawValue: base + 4 * offset + kind.rawValue)
    }

    private func locate(_ id: NodeID) -> (offset: UInt64, kind: Kind)? {
        guard id.rawValue >= base else { return nil }
        let raw = id.rawValue - base
        let offset = raw / 4
        guard offset <= file.fileSize, let kind = Kind(rawValue: raw % 4) else { return nil }
        return (offset, kind)
    }

    // MARK: Fields

    private struct Field {
        let start: UInt64
        let end: UInt64
    }

    private static func fields(ofRowAt offset: UInt64, in file: MappedFile,
                               delimiter: UInt8) -> [Field] {
        let bytes = file.rawPointer.assumingMemoryBound(to: CChar.self)
        let d = CChar(bitPattern: delimiter)
        var starts = [UInt64](repeating: 0, count: 32)
        var ends = [UInt64](repeating: 0, count: 32)
        var count = ms_csv_fields(bytes, file.fileSize, d, offset, &starts, &ends, 32, nil)
        if count > 32 {
            starts = [UInt64](repeating: 0, count: Int(count))
            ends = [UInt64](repeating: 0, count: Int(count))
            count = ms_csv_fields(bytes, file.fileSize, d, offset, &starts, &ends, count, nil)
        }
        return (0 ..< Int(count)).map { Field(start: starts[$0], end: ends[$0]) }
    }

    /// The field's text: unquoted, with `""` as `"`, decoded as the file is.
    private static func text(of field: Field, in file: MappedFile, utf8: Bool) -> String {
        let bytes = UnsafeRawBufferPointer(start: file.rawPointer + Int(field.start),
                                           count: Int(field.end - field.start))
        func decode(_ b: UnsafeRawBufferPointer) -> String {
            utf8 ? String(decoding: b, as: UTF8.self)
                 : String(bytes: b, encoding: .isoLatin1) ?? ""
        }
        guard bytes.first == UInt8(ascii: "\"") else { return decode(bytes) }
        // Read it as CSVParser does: a quote ends the field unless doubled.
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 1
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\"") {
                guard i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "\"") else { break }
                out.append(UInt8(ascii: "\""))
                i += 2
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out.withUnsafeBytes(decode)
    }

    /// The fields of the row last read. A row's cells are built right after
    /// the row, one by one, and each needs the row's fields: without this,
    /// walking a row of n cells would read it 2n more times.
    private var lastRow: (offset: UInt64, fields: [Field])?
    private let lastRowLock = NSLock()

    private func fields(ofRowAt offset: UInt64) -> [Field] {
        if let cached = lastRowLock.withLock({ lastRow }), cached.offset == offset {
            return cached.fields
        }
        let fields = Self.fields(ofRowAt: offset, in: file, delimiter: delimiter)
        lastRowLock.withLock { lastRow = (offset, fields) }
        return fields
    }

    /// The row holding the byte at `offset`, by binary search.
    private func row(containing offset: UInt64) -> UInt64? {
        var lo = 0, hi = rowOffsets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rowOffsets[mid] <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? rowOffsets[lo - 1] : nil
    }

    /// The cell starting at `offset`: its row, column and field.
    private func cell(at offset: UInt64) -> (row: UInt64, column: Int, field: Field)? {
        // No two fields start at the same byte, so a field of the row last
        // read that starts here is the cell.
        if let cached = lastRowLock.withLock({ lastRow }),
           let column = cached.fields.firstIndex(where: { $0.start == offset }) {
            return (cached.offset, column, cached.fields[column])
        }
        guard let row = row(containing: offset) else { return nil }
        let fields = fields(ofRowAt: row)
        guard let column = fields.firstIndex(where: { $0.start == offset }) else { return nil }
        return (row, column, fields[column])
    }

    // MARK: DocumentSource

    public func node(for id: NodeID, parent: DocumentNode?, internKeys: Bool) -> DocumentNode? {
        guard let (offset, kind) = locate(id) else { return nil }
        switch kind {
        case .root:
            guard offset == 0 else { return nil }
            return DocumentNode(id: id, type: .array, depth: 0,
                                childIDs: rowOffsets.map { self.id($0, .row) },
                                value: .container(childCount: rowOffsets.count),
                                metadata: rootMetadata)

        case .row:
            let fields = fields(ofRowAt: offset)
            let end = fields.last?.end ?? offset
            return DocumentNode(id: id, type: hasHeader ? .object : .array, depth: 1,
                                parentID: rootID,
                                childIDs: fields.map { self.id($0.start, hasHeader ? .key : .value) },
                                value: .container(childCount: fields.count),
                                sourceRange: SourceRange(byteOffset: offset,
                                                         byteLength: UInt32(clamping: end - offset)))

        case .key:
            guard hasHeader, let cell = cell(at: offset), cell.column < keys.count else { return nil }
            return DocumentNode(id: id, type: .keyValue, depth: 2,
                                parentID: self.id(cell.row, .row),
                                childIDs: [self.id(offset, .value)], key: keys[cell.column],
                                value: .unparsed,
                                sourceRange: range(of: cell.field))

        case .value:
            guard let cell = cell(at: offset) else { return nil }
            let text = Self.text(of: cell.field, in: file, utf8: isUTF8)
            return DocumentNode(id: id, type: .scalar, depth: hasHeader ? 3 : 2,
                                parentID: hasHeader ? self.id(offset, .key) : self.id(cell.row, .row),
                                key: hasHeader ? nil : String(cell.column),
                                value: .scalar(parseScalarValue(text)),
                                sourceRange: range(of: cell.field),
                                metadata: columnMetadata[min(cell.column, columnMetadata.count - 1)])
        }
    }

    private func range(of field: Field) -> SourceRange {
        SourceRange(byteOffset: field.start, byteLength: UInt32(clamping: field.end - field.start))
    }

    public func path(to id: NodeID) -> [NodeID] {
        guard let (offset, kind) = locate(id) else { return [] }
        switch kind {
        case .root:
            return offset == 0 ? [rootID] : []
        case .row:
            return row(containing: offset) == offset ? [rootID, id] : []
        case .key:
            guard hasHeader, let cell = cell(at: offset) else { return [] }
            return [rootID, self.id(cell.row, .row), id]
        case .value:
            guard let cell = cell(at: offset) else { return [] }
            let row = self.id(cell.row, .row)
            return hasHeader ? [rootID, row, self.id(offset, .key), id] : [rootID, row, id]
        }
    }

    public func looksTabular() -> Bool {
        guard hasHeader, !rowOffsets.isEmpty else { return false }
        let counts = rowOffsets.prefix(10).map { fields(ofRowAt: $0).count }
        return counts.allSatisfy { $0 > 0 && $0 == counts[0] }
    }

    // MARK: Search

    /// What a search needs for every row, worked out once per query: a
    /// search calls `searchUnloaded` for each of up to millions of rows.
    private struct PreparedQuery {
        let query: String
        /// Whether each column's key matches: the header name, or without
        /// one the column's position. Every cell under it is a key match.
        let keyMatches: [Bool]
        let columns: [UInt8]
        /// The query's UTF-8 bytes, for the byte filter.
        let needle: [UInt8]
    }

    private var preparedQuery: PreparedQuery?
    private let preparedLock = NSLock()

    private func prepare(_ query: String) -> PreparedQuery {
        preparedLock.lock()
        defer { preparedLock.unlock() }
        if let prepared = preparedQuery, prepared.query == query { return prepared }
        let keyMatches = keys.map { $0.lowercased().contains(query) }
        let prepared = PreparedQuery(query: query, keyMatches: keyMatches,
                                     columns: keyMatches.map { $0 ? 1 : 0 },
                                     needle: Array(query.utf8))
        preparedQuery = prepared
        return prepared
    }

    /// Searches unloaded rows from their bytes: cells whose bytes show they
    /// can't match are skipped without being decoded. Takes the leading IDs
    /// that are consecutive rows of the file; an edit can reorder or insert
    /// rows, and those are left to the caller.
    public func searchUnloaded(_ ids: ArraySlice<NodeID>, query: String,
                               _ match: (NodeID, SearchMatch.Field, String) -> Bool) -> Int {
        guard let (first, kind) = locate(ids[ids.startIndex]), kind == .row,
              var position = rowIndex(of: first) else { return 0 }
        var count = 0
        for id in ids {
            guard position < rowOffsets.count, id == self.id(rowOffsets[position], .row) else { break }
            count += 1
            position += 1
        }

        let prepared = prepare(query)
        let keyMatches = prepared.keyMatches

        typealias Visit = (MSCSVField) -> Bool
        withoutActuallyEscaping({ (field: MSCSVField) -> Bool in
            let column = Int(field.column)
            let cell = Field(start: field.start, end: field.end)
            let row = self.id(field.start, self.hasHeader ? .key : .value)
            if column < keyMatches.count, keyMatches[column],
               !match(row, .key, self.keys[column]) { return false }
            let text = parseScalarValue(Self.text(of: cell, in: self.file, utf8: self.isUTF8))
                .searchableText
            guard text.lowercased().contains(query) else { return true }
            return match(row, .value, text)
        } as Visit) { body in
            var box = body
            withUnsafeMutablePointer(to: &box) { context in
                prepared.needle.withUnsafeBufferPointer { n in
                    n.withMemoryRebound(to: CChar.self) { n in
                        prepared.columns.withUnsafeBufferPointer { c in
                            ms_csv_search_rows(file.rawPointer.assumingMemoryBound(to: CChar.self),
                                               file.fileSize, CChar(bitPattern: delimiter),
                                               first, UInt64(count),
                                               n.baseAddress, UInt64(n.count),
                                               c.baseAddress, UInt64(c.count),
                                               { context, field in
                                                   let visit = context!.assumingMemoryBound(to: Visit.self)
                                                   return visit.pointee(field!.pointee) ? 1 : 0
                                               }, context)
                        }
                    }
                }
            }
        }
        return count
    }

    /// The position of the row starting at `offset` among the data rows.
    private func rowIndex(of offset: UInt64) -> Int? {
        var lo = 0, hi = rowOffsets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rowOffsets[mid] < offset { lo = mid + 1 } else { hi = mid }
        }
        return lo < rowOffsets.count && rowOffsets[lo] == offset ? lo : nil
    }
}
