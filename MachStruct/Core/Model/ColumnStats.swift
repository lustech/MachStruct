import Foundation

// MARK: - ColumnStats

/// Per-column statistics of a tabular document: an array of objects, with
/// the columns taken from the first row's keys.
public struct ColumnStats: Identifiable, Equatable, Sendable {
    public let id:          String   // column name
    public var totalRows:   Int      = 0
    public var emptyCount:  Int      = 0
    public var intCount:    Int      = 0
    public var floatCount:  Int      = 0
    public var stringCount: Int      = 0
    public var uniqueValues: Set<String> = []
    public var numMin:      Double   = .greatestFiniteMagnitude
    public var numMax:      Double   = -.greatestFiniteMagnitude

    public init(id: String) { self.id = id }

    public var nonEmpty:    Int    { totalRows - emptyCount }
    public var uniqueCount: Int    { uniqueValues.count }

    public var detectedType: String {
        guard nonEmpty > 0 else { return "Empty" }
        if intCount   == nonEmpty { return "Integer" }
        if intCount + floatCount == nonEmpty { return "Decimal" }
        if stringCount == nonEmpty { return "String" }
        return "Mixed"
    }

    public var hasNumericRange: Bool {
        numMin <= numMax
    }

    /// Counts one row's cell: `nil` when the row has no scalar for the column.
    mutating func record(_ value: ScalarValue?) {
        totalRows += 1
        switch value {
        case nil, .null?:
            emptyCount += 1

        case .string(let s)?:
            if s.isEmpty {
                emptyCount += 1
            } else {
                stringCount += 1
                remember(s)
            }

        case .integer(let n)?:
            intCount += 1
            let d = Double(n)
            numMin = min(numMin, d)
            numMax = max(numMax, d)
            remember(String(n))

        case .float(let f)?:
            floatCount += 1
            numMin = min(numMin, f)
            numMax = max(numMax, f)
            remember(String(f))

        case .boolean(let b)?:
            stringCount += 1
            remember(b ? "true" : "false")
        }
    }

    /// Unique values are counted up to 100; the panel shows "100+" beyond.
    private mutating func remember(_ value: String) {
        if uniqueValues.count < 100 { uniqueValues.insert(value) }
    }
}

// MARK: - Computing

extension ColumnStats {

    /// The statistics of a fully built `index`.
    public static func compute(in index: NodeIndex) -> [ColumnStats] {
        let columns = index.tabularColumns
        guard !columns.isEmpty, let root = index.root else { return [] }

        var result = columns.map { ColumnStats(id: $0) }
        for row in index.children(of: root.id) {
            let kvs = index.children(of: row.id)
            for (i, column) in columns.enumerated() {
                var value: ScalarValue?
                if let kv = kvs.first(where: { $0.key == column }),
                   let child = index.children(of: kv.id).first,
                   case .scalar(let sv) = child.value {
                    value = sv
                }
                result[i].record(value)
            }
        }
        return result
    }

    /// The statistics of a large document as edited, in one pass over it:
    /// nodes in `index` are read from there and the rest built from `source`
    /// as they are reached, without keeping them.
    public static func compute(in index: NodeIndex,
                               source: any DocumentSource) -> [ColumnStats] {
        let columns = tabularColumns(of: index, source: source)
        guard !columns.isEmpty else { return [] }

        // A column takes the row's first member with its name, as above.
        var positions = [String: [Int]]()
        for (i, column) in columns.enumerated() { positions[column, default: []].append(i) }

        var result = columns.map { ColumnStats(id: $0) }
        var cells = [ScalarValue?](repeating: nil, count: columns.count)
        var seen = Set<String>()
        var rowID: NodeID?
        var key: String?

        func finishRow() {
            guard rowID != nil else { return }
            for i in result.indices { result[i].record(cells[i]) }
            cells = [ScalarValue?](repeating: nil, count: columns.count)
            seen.removeAll(keepingCapacity: true)
        }

        source.traverse(overlaying: index) { node, parent in
            guard let parent else { return true }            // the root
            if parent.id == index.rootID {                    // a row
                finishRow()
                rowID = node.id
                return node.type == .object
            }
            if parent.id == rowID {                           // a row's member
                key = nil
                if node.type == .keyValue, let name = node.key, positions[name] != nil,
                   seen.insert(name).inserted { key = name }
                return key != nil
            }
            // A member's value, which is a cell when it is a scalar.
            if let name = key, case .scalar(let sv) = node.value, let slots = positions[name] {
                for i in slots { cells[i] = sv }
            }
            key = nil
            return false
        }
        finishRow()
        return result
    }

    /// The first row's keys, as `NodeIndex.tabularColumns` gives them.
    private static func tabularColumns(of index: NodeIndex,
                                       source: any DocumentSource) -> [String] {
        func node(_ id: NodeID, _ parent: DocumentNode?) -> DocumentNode? {
            index.node(for: id) ?? source.node(for: id, parent: parent, internKeys: false)
        }
        guard let root = index.root, root.type == .array,
              let firstID = root.childIDs.first,
              let first = node(firstID, root) else { return [] }
        return first.childIDs.compactMap { node($0, first)?.key }
    }
}
