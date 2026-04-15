import Foundation

// MARK: - IndexEntry

/// One entry in the structural index — represents one node's position, type, and relationships.
///
/// Produced by Phase 1 (structural indexing). Values are populated lazily in Phase 2
/// via `StructParser.parseValue(entry:from:)`.
public struct IndexEntry: Sendable {

    public let id: NodeID

    /// Byte offset of this node's raw source in the file. 0 when not yet extracted.
    public let byteOffset: UInt64

    /// Byte length of this node's raw source. 0 when not yet extracted.
    public let byteLength: UInt32

    public let nodeType: NodeType
    public let depth: UInt16
    public let parentID: NodeID?
    public let childCount: UInt32

    /// Object key or string-encoded array index for `.keyValue` / array-element nodes.
    /// Populated eagerly on the Foundation path; `nil` on the simdjson path (lazily parsed).
    public let key: String?

    /// Eagerly parsed leaf value (Foundation path only).
    /// `nil` on the simdjson path — use `StructParser.parseValue` to obtain.
    public let parsedValue: ScalarValue?

    /// Format-specific metadata (e.g. `XMLMetadata` for XML nodes). Populated eagerly
    /// by format parsers that have this information at index-build time.
    public let metadata: FormatMetadata?

    public init(
        id: NodeID,
        byteOffset: UInt64 = 0,
        byteLength: UInt32 = 0,
        nodeType: NodeType,
        depth: UInt16,
        parentID: NodeID?,
        childCount: UInt32 = 0,
        key: String? = nil,
        parsedValue: ScalarValue? = nil,
        metadata: FormatMetadata? = nil
    ) {
        self.id = id
        self.byteOffset = byteOffset
        self.byteLength = byteLength
        self.nodeType = nodeType
        self.depth = depth
        self.parentID = parentID
        self.childCount = childCount
        self.key = key
        self.parsedValue = parsedValue
        self.metadata = metadata
    }
}

// MARK: - StructuralIndex

/// The output of Phase 1 parsing: a flat array of `IndexEntry`s in document order.
///
/// Convert to a fully navigable `NodeIndex` via `buildNodeIndex()` (eager, all nodes)
/// or `buildShallowNodeIndex()` (lazy — root + first visible level only).
public struct StructuralIndex: Sendable {

    public let entries: [IndexEntry]
    public var count: Int { entries.count }

    /// Maps each NodeID → indices of its immediate children in `entries`.
    /// Precomputed once in O(n); enables O(childCount) lazy expansion without
    /// scanning the full entry list.
    public let childIndices: [NodeID: [Int]]

    /// Base NodeID rawValue for the first entry in `entries`.
    ///
    /// NodeIDs are assigned by a global monotonic counter in document order, so
    /// `entries[i].id.rawValue == entryIDBase + UInt64(i)` for all i.
    /// This lets `entry(for:)` resolve a NodeID → index in O(1) with a single
    /// subtraction + bounds-check instead of a hash-table lookup, eliminating the
    /// ~30 ms overhead of building an N-entry `[NodeID: Int]` dictionary.
    public let entryIDBase: UInt64

    /// Intern pool for `DocumentNode.key` strings built from the eagerly-parsed
    /// `IndexEntry.key` values (Foundation path).  Pre-populated at init time so
    /// that `buildNodeIndex` / `buildShallowNodeIndex` can look up the canonical
    /// instance for each key without re-hashing.
    ///
    /// On the simdjson path all `IndexEntry.key` values are `nil`; the table
    /// starts empty and is populated lazily during materialisation so that
    /// sibling nodes sharing key names still benefit from interning.
    public let keyTable: StringTable

    public init(entries: [IndexEntry]) {
        self.entries = entries
        self.entryIDBase = entries.first?.id.rawValue ?? 0
        var ci = [NodeID: [Int]]()
        ci.reserveCapacity(entries.count / 4)
        for (i, entry) in entries.enumerated() {
            if let pid = entry.parentID {
                ci[pid, default: []].append(i)
            }
        }
        self.childIndices = ci
        // Start empty — keys are interned on demand as nodes are materialised.
        // Preloading (iterating all entries at init time) was measured to add
        // ~95 ms for large files on the simdjson path where every key is nil.
        self.keyTable = StringTable()
    }

    /// O(1) lookup of an `IndexEntry` by node ID.
    ///
    /// Uses arithmetic on the globally-monotonic NodeID counter rather than a
    /// hash-table — `entries[id.rawValue - entryIDBase]` with a bounds check.
    public func entry(for id: NodeID) -> IndexEntry? {
        guard id.rawValue >= entryIDBase else { return nil }
        let i = Int(id.rawValue - entryIDBase)
        guard i < entries.count else { return nil }
        return entries[i]
    }

    /// Ancestor path from root down to (and including) `id`, derived purely
    /// from `IndexEntry.parentID` — no `NodeIndex` required.
    ///
    /// Returns `[]` if `id` is not found in `entries`.
    public func path(to id: NodeID) -> [NodeID] {
        guard entry(for: id) != nil else { return [] }
        var result: [NodeID] = []
        var current: NodeID? = id
        while let cid = current {
            result.append(cid)
            current = entry(for: cid)?.parentID
        }
        return result.reversed()
    }

    // MARK: - Full (eager) build

    /// Build a `NodeIndex` (DocumentNode tree) from this structural index.
    ///
    /// - Container nodes (.object, .array) get `value: .container(childCount:)`.
    /// - Scalar nodes use the eagerly-parsed `parsedValue` if available, else `.unparsed`.
    /// - Parent–child wiring is derived from `IndexEntry.parentID`.
    public func buildNodeIndex() -> NodeIndex {
        guard let first = entries.first else {
            let root = DocumentNode(type: .object, value: .container(childCount: 0))
            return NodeIndex(root: root)
        }

        // Build the flat storage and positions index in one pass, then wire
        // childIDs in a second pass — eliminating the extra dict-to-array
        // conversion that `NodeIndex(rootID:allNodes:)` would require.
        var storage   = ContiguousArray<DocumentNode>()
        var positions = [NodeID: Int](minimumCapacity: entries.count)
        var childIDsByParent = [NodeID: [NodeID]]()
        storage.reserveCapacity(entries.count)
        childIDsByParent.reserveCapacity(entries.count / 2)

        for entry in entries {
            let value: NodeValue
            switch entry.nodeType {
            case .object, .array:
                value = .container(childCount: Int(entry.childCount))
            case .scalar:
                value = entry.parsedValue.map { .scalar($0) } ?? .unparsed
            case .keyValue:
                value = .unparsed
            }

            positions[entry.id] = storage.count
            storage.append(DocumentNode(
                id: entry.id,
                type: entry.nodeType,
                depth: entry.depth,
                parentID: entry.parentID,
                childIDs: [],
                key: keyTable.intern(entry.key),
                value: value,
                sourceRange: SourceRange(byteOffset: entry.byteOffset,
                                         byteLength: entry.byteLength),
                metadata: entry.metadata
            ))

            if let pid = entry.parentID {
                childIDsByParent[pid, default: []].append(entry.id)
            }
        }

        // Wire up childIDs
        for (pid, childIDs) in childIDsByParent {
            guard let idx = positions[pid] else { continue }
            storage[idx].childIDs = childIDs
        }

        return NodeIndex(rootID: first.id, storage: storage, positions: positions)
    }

    // MARK: - Shallow (lazy) build

    /// Build a `NodeIndex` containing only the root and its immediate visible children.
    ///
    /// For `.keyValue` nodes in the root, their value children are also materialized
    /// so display properties (`displayValue`, `badgeInfo`) work on the initial render.
    /// Deeper nodes are added on demand via `StructDocument.materializeChildrenIfNeeded`.
    ///
    /// Compared to `buildNodeIndex()`, this is O(visible_nodes) instead of O(all_nodes),
    /// which reduces memory and startup time dramatically for large files.
    public func buildShallowNodeIndex() -> NodeIndex {
        guard let first = entries.first else {
            let root = DocumentNode(type: .object, value: .container(childCount: 0))
            return NodeIndex(root: root)
        }

        // Rough capacity: root + root children + their value/kv children.
        let rootChildIdxs = childIndices[first.id] ?? []
        var nodes = [NodeID: DocumentNode]()
        nodes.reserveCapacity(1 + rootChildIdxs.count * 3)

        // Root node
        let rootChildIDs = rootChildIdxs.map { entries[$0].id }
        nodes[first.id] = makeDocumentNode(from: first, childIDs: rootChildIDs)

        // Root's immediate children + one extra level (value children of keyValue nodes)
        for childIdx in rootChildIdxs {
            let childEntry = entries[childIdx]
            let grandChildIdxs = childIndices[childEntry.id] ?? []
            let grandChildIDs = grandChildIdxs.map { entries[$0].id }
            nodes[childEntry.id] = makeDocumentNode(from: childEntry, childIDs: grandChildIDs)

            // For keyValue nodes, also materialise the value child so the row can
            // render its display value and badge without needing a separate parse.
            if childEntry.nodeType == .keyValue {
                for gcIdx in grandChildIdxs {
                    let gcEntry = entries[gcIdx]
                    let ggChildIDs = (childIndices[gcEntry.id] ?? []).map { entries[$0].id }
                    nodes[gcEntry.id] = makeDocumentNode(from: gcEntry, childIDs: ggChildIDs)
                }
            }
        }

        return NodeIndex(rootID: first.id, allNodes: nodes)
    }

    // MARK: - Tabular heuristic

    /// Returns `true` when the structural index looks tabular without requiring full
    /// materialisation.  Uses child-count heuristics rather than key-name comparison,
    /// so it works even on the simdjson path where `IndexEntry.key` is nil.
    public func looksTabular(sampleSize: Int = 10) -> Bool {
        guard let rootEntry = entries.first, rootEntry.nodeType == .array else { return false }
        guard let rootChildIdxs = childIndices[rootEntry.id],
              !rootChildIdxs.isEmpty else { return false }

        let sample = rootChildIdxs.prefix(sampleSize)
        // All sampled items must be objects.
        guard sample.allSatisfy({ entries[$0].nodeType == .object }) else { return false }

        // All sampled objects must have the same child count.
        let firstCount = childIndices[entries[sample[0]].id]?.count ?? 0
        guard firstCount > 0 else { return false }
        guard sample.allSatisfy({
            (childIndices[entries[$0].id]?.count ?? 0) == firstCount
        }) else { return false }

        // If keys are available (Foundation path), also verify they match.
        if let firstItemChildIdxs = childIndices[entries[sample[0]].id],
           firstItemChildIdxs.first.map({ entries[$0].key }) != nil {
            let firstKeys = firstItemChildIdxs.compactMap { entries[$0].key }
            guard firstKeys.count == firstCount else { return false }
            return sample.allSatisfy { itemIdx in
                let keys = (childIndices[entries[itemIdx].id] ?? []).compactMap { entries[$0].key }
                return keys == firstKeys
            }
        }

        return true
    }

    // MARK: - Internal helpers

    func makeDocumentNode(from entry: IndexEntry, childIDs: [NodeID]) -> DocumentNode {
        let value: NodeValue
        switch entry.nodeType {
        case .object, .array:
            value = .container(childCount: Int(entry.childCount))
        case .scalar:
            value = entry.parsedValue.map { .scalar($0) } ?? .unparsed
        case .keyValue:
            value = .unparsed
        }
        return DocumentNode(
            id: entry.id,
            type: entry.nodeType,
            depth: entry.depth,
            parentID: entry.parentID,
            childIDs: childIDs,
            key: keyTable.intern(entry.key),   // intern so repeated keys share backing
            value: value,
            sourceRange: SourceRange(byteOffset: entry.byteOffset,
                                     byteLength: entry.byteLength),
            metadata: entry.metadata
        )
    }
}

// MARK: - ValidationIssue

/// A non-fatal parse issue (trailing comma, comment, encoding warning, etc.).
public struct ValidationIssue: Sendable {
    public enum Severity: Sendable { case warning, error }

    public let severity: Severity
    public let message: String
    public let byteOffset: UInt64

    public init(severity: Severity, message: String, byteOffset: UInt64 = 0) {
        self.severity = severity
        self.message = message
        self.byteOffset = byteOffset
    }
}

// MARK: - ParseProgress

/// Emitted by `StructParser.parseProgressively(file:)` as parsing proceeds.
public enum ParseProgress: Sendable {
    /// A batch of newly indexed nodes — enough to render the visible portion of the tree.
    case nodesIndexed([IndexEntry])
    /// Parsing is complete; the full index is available.
    case complete(StructuralIndex)
    /// A recoverable issue (e.g. trailing comma in JSON).
    case warning(ValidationIssue)
    /// A fatal error; parsing stopped.
    case error(Error)
}

// MARK: - StructParser

/// The sole extension point for new document formats.
///
/// Implement this protocol to add XML, YAML, CSV, or any future format.
/// All format-specific logic lives here; the rest of MachStruct is format-agnostic.
public protocol StructParser: Sendable {

    /// Supported file extensions, lowercase, no leading dot (e.g. `"json"`).
    static var supportedExtensions: Set<String> { get }

    /// Phase 1 — Build a structural index.
    /// Must be fast: only node locations and types, no value parsing.
    func buildIndex(from file: MappedFile) async throws -> StructuralIndex

    /// Stream the structural index progressively for large files.
    /// The UI subscribes and renders nodes as they arrive.
    func parseProgressively(file: MappedFile) -> AsyncStream<ParseProgress>

    /// Phase 2 — Parse the value of a single node on demand.
    /// Called lazily when a node becomes visible or is selected for editing.
    func parseValue(entry: IndexEntry, from file: MappedFile) throws -> NodeValue

    /// Serialize a modified node value back to format-specific text bytes.
    func serialize(value: NodeValue) throws -> Data

    /// Validate the file and return any issues. May be slow — run in background.
    func validate(file: MappedFile) async throws -> [ValidationIssue]
}

// MARK: - ParserRegistry

/// Maps file extensions to registered `StructParser` instances.
///
/// Also provides `parser(for:file:)` which combines content-based detection
/// (`FormatDetector`) with the extension-keyed registry for a best-effort match.
public actor ParserRegistry {
    public static let shared = ParserRegistry()

    private var parsers: [String: any StructParser] = [:]

    private init() {}

    public func register(_ parser: any StructParser) {
        for ext in type(of: parser).supportedExtensions {
            parsers[ext.lowercased()] = parser
        }
    }

    /// Look up a parser by file extension only.
    public func parser(for fileExtension: String) -> (any StructParser)? {
        parsers[fileExtension.lowercased()]
    }

    /// Sniff `file` content and return the best matching parser.
    ///
    /// Falls back to extension-based lookup if content sniffing is inconclusive.
    public func parser(for file: MappedFile, fileExtension: String?) -> (any StructParser)? {
        let detected = FormatDetector.detect(file: file, fileExtension: fileExtension)
        switch detected {
        case .json:    return parsers["json"]
        case .xml:     return parsers["xml"]
        case .yaml:    return parsers["yaml"]
        case .csv:     return parsers["csv"]
        case .unknown: return fileExtension.flatMap { parsers[$0.lowercased()] }
        }
    }
}
