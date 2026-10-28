import Foundation

// MARK: - IndexEntry

/// One entry in the structural index — represents one node's position, type, and relationships.
///
/// Produced by Phase 1 (structural indexing). Values are populated lazily in Phase 2
/// via `StructParser.parseValue(entry:from:)`.
public struct IndexEntry: Sendable {

    // Stored properties are ordered largest first so they pack without
    // padding: a 400 000-row file has 2.8 million entries (#62).

    public fileprivate(set) var id: NodeID

    /// Byte offset of this node's raw source in the file. 0 when not yet extracted.
    public let byteOffset: UInt64

    /// Object key or string-encoded array index for `.keyValue` / array-element nodes.
    /// Populated eagerly on the Foundation path; `nil` on the simdjson path (lazily parsed).
    public let key: String?

    /// Eagerly parsed leaf value (Foundation path only).
    /// `nil` on the simdjson path — use `StructParser.parseValue` to obtain.
    public let parsedValue: ScalarValue?

    /// Boxed: few entries have metadata, and inline it took 56 bytes of every one.
    private var metadataBox: MetadataBox?

    public fileprivate(set) var parentID: NodeID?

    /// Byte length of this node's raw source. 0 when not yet extracted.
    public let byteLength: UInt32

    public let childCount: UInt32
    public let depth: UInt16
    public let nodeType: NodeType

    /// Format-specific metadata (e.g. `XMLMetadata` for XML nodes). Populated eagerly
    /// by format parsers that have this information at index-build time.
    public var metadata: FormatMetadata? { metadataBox?.value }

    /// Metadata that many entries can share: parsers that give the same
    /// metadata to many entries pass one box rather than a copy for each.
    final class MetadataBox: Sendable {
        let value: FormatMetadata
        init(_ value: FormatMetadata) { self.value = value }
    }

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
        self.metadataBox = metadata.map(MetadataBox.init)
    }

    init(
        id: NodeID,
        nodeType: NodeType,
        depth: UInt16,
        parentID: NodeID?,
        childCount: UInt32 = 0,
        key: String? = nil,
        parsedValue: ScalarValue? = nil,
        sharedMetadata: MetadataBox
    ) {
        self.init(id: id, nodeType: nodeType, depth: depth, parentID: parentID,
                  childCount: childCount, key: key, parsedValue: parsedValue)
        self.metadataBox = sharedMetadata
    }

    /// This entry with its place in the tree or its child count changed,
    /// for parsers that learn them after appending it.
    func with(depth: UInt16? = nil, parentID: NodeID?? = nil, key: String?? = nil,
              childCount: UInt32? = nil) -> IndexEntry {
        var entry = IndexEntry(id: id, byteOffset: byteOffset, byteLength: byteLength,
                               nodeType: nodeType, depth: depth ?? self.depth,
                               parentID: parentID ?? self.parentID,
                               childCount: childCount ?? self.childCount,
                               key: key ?? self.key, parsedValue: parsedValue)
        entry.metadataBox = metadataBox
        return entry
    }
}

// MARK: - StructuralIndex

/// The children of each entry in a `StructuralIndex`, as indices into its
/// `entries` in document order.
///
/// Stored as one flat list plus an offset per entry. An array per container
/// took 1.6 million allocations and 170 MB for a 400 000-row CSV (#62).
public struct ChildIndexTable: Sendable {

    private let base: UInt64
    /// `flat[starts[i]..<starts[i + 1]]` are the children of `entries[i]`.
    private let starts: [Int]
    private let flat: [Int]

    /// `entries` must be numbered contiguously from `base`, which
    /// `StructuralIndex.init` guarantees.
    init(entries: [IndexEntry], base: UInt64) {
        let n = entries.count
        func parentIndex(_ entry: IndexEntry) -> Int? {
            guard let pid = entry.parentID, pid.rawValue >= base,
                  pid.rawValue - base < UInt64(n) else { return nil }
            return Int(pid.rawValue - base)
        }

        var starts = [Int](repeating: 0, count: n + 1)
        for entry in entries {
            if let p = parentIndex(entry) { starts[p + 1] += 1 }
        }
        for i in 0..<n { starts[i + 1] += starts[i] }

        var flat = [Int](repeating: 0, count: starts[n])
        var next = starts
        for (i, entry) in entries.enumerated() {
            if let p = parentIndex(entry) {
                flat[next[p]] = i
                next[p] += 1
            }
        }
        self.base = base
        self.starts = starts
        self.flat = flat
    }

    /// The children of the node `id`, or `nil` when it has none or isn't in
    /// the index.
    public subscript(id: NodeID) -> ArraySlice<Int>? {
        guard id.rawValue >= base, id.rawValue - base < UInt64(starts.count - 1) else { return nil }
        let i = Int(id.rawValue - base)
        let range = starts[i]..<starts[i + 1]
        return range.isEmpty ? nil : flat[range]
    }
}

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
    public let childIndices: ChildIndexTable

    /// Base NodeID rawValue for the first entry in `entries`.
    ///
    /// `entries[i].id.rawValue == entryIDBase + UInt64(i)` for all i. `init`
    /// *enforces* this: NodeIDs are globally monotonic but not contiguous when
    /// two documents parse concurrently (issue #14), so a non-contiguous run is
    /// renumbered onto a freshly reserved block before the index is built.
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
        // `entry(for:)` resolves IDs by arithmetic, which requires this
        // document's IDs to be contiguous. Concurrent parses interleave the
        // global counter, so repair the run before anything depends on it.
        var entries = entries
        if !StructuralIndex.idsAreContiguous(entries) {
            StructuralIndex.renumberContiguously(&entries)
        }
        self.entries = entries
        self.entryIDBase = entries.first?.id.rawValue ?? 0
        self.childIndices = ChildIndexTable(entries: entries, base: entryIDBase)
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
        let candidate = entries[i]
        // Confirm the arithmetic landed on the node actually asked for. Without
        // this a stale or foreign ID resolves to whichever node occupies that
        // slot, silently returning another node's data instead of nothing.
        guard candidate.id == id else { return nil }
        return candidate
    }

    /// True when `entries[i].id == entryIDBase + i` throughout — the invariant
    /// `entry(for:)` depends on. O(n), no allocation; the common case.
    private static func idsAreContiguous(_ entries: [IndexEntry]) -> Bool {
        guard let base = entries.first?.id.rawValue else { return true }
        for (i, entry) in entries.enumerated()
        where entry.id.rawValue != base &+ UInt64(i) {
            return false
        }
        return true
    }

    /// Reassign every ID onto a freshly reserved contiguous block, rewriting
    /// `parentID` links to match. Only runs when contiguity was broken, so the
    /// `[NodeID: NodeID]` remap is off the hot path.
    private static func renumberContiguously(_ entries: inout [IndexEntry]) {
        guard !entries.isEmpty else { return }
        let base = NodeID.reserveBlock(count: entries.count)

        var remap = [NodeID: NodeID](minimumCapacity: entries.count)
        for (i, entry) in entries.enumerated() {
            remap[entry.id] = NodeID(rawValue: base &+ UInt64(i))
        }
        for i in entries.indices {
            if let newID = remap[entries[i].id] { entries[i].id = newID }
            // A parent outside this document would be corrupt input; leaving it
            // unmapped makes `entry(for:)` reject it rather than mis-resolve it.
            if let parent = entries[i].parentID, let newParent = remap[parent] {
                entries[i].parentID = newParent
            }
        }
    }

    /// Ancestor path from root down to (and including) `id`, derived purely
    /// from `IndexEntry.parentID` — no `NodeIndex` required.
    ///
    /// Returns `[]` if `id` is not found in `entries`.
    public func path(to id: NodeID) -> [NodeID] {
        guard entry(for: id) != nil else { return [] }
        var result: [NodeID] = []
        var current: NodeID? = id
        // A corrupted parent chain can cycle. This walk runs on the main actor
        // behind search navigation, so an unbounded loop beachballs the app and
        // grows `result` until it exhausts memory — bail out instead.
        while let cid = current {
            result.append(cid)
            guard result.count <= entries.count else { return [] }
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

        // Build the flat storage and positions index in one pass, taking each
        // node's children from `childIndices` rather than collecting them in
        // a dictionary first.
        var storage   = ContiguousArray<DocumentNode>()
        var positions = [NodeID: Int](minimumCapacity: entries.count)
        storage.reserveCapacity(entries.count)

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
                childIDs: (childIndices[entry.id] ?? []).map { entries[$0].id },
                key: keyTable.intern(entry.key),
                value: value,
                sourceRange: SourceRange(byteOffset: entry.byteOffset,
                                         byteLength: entry.byteLength),
                metadata: entry.metadata
            ))
        }

        return NodeIndex(rootID: first.id, storage: storage, positions: positions)
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
        let firstCount = childIndices[entries[sample[sample.startIndex]].id]?.count ?? 0
        guard firstCount > 0 else { return false }
        guard sample.allSatisfy({
            (childIndices[entries[$0].id]?.count ?? 0) == firstCount
        }) else { return false }

        // If keys are available (Foundation path), also verify they match.
        if let firstItemChildIdxs = childIndices[entries[sample[sample.startIndex]].id],
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
    /// The number of nodes indexed since the last report.
    case nodesIndexed(Int)
    /// Parsing is complete; the full index is available.
    case complete(StructuralIndex)
    /// A recoverable issue (e.g. trailing comma in JSON).
    case warning(ValidationIssue)
    /// A fatal error; parsing stopped.
    case error(Error)

    /// Runs `build` in the background, then reports the node count in batches
    /// of 1 000 followed by the finished index.
    ///
    /// Batches carry counts, not entries: the index is complete before the
    /// first report, and the stream buffers every report until the consumer
    /// reads it, so copies of the entries amounted to a second index (#62).
    static func stream(
        _ build: @escaping @Sendable () async throws -> StructuralIndex
    ) -> AsyncStream<ParseProgress> {
        AsyncStream { continuation in
            Task {
                do {
                    let index = try await build()
                    let batchSize = 1_000
                    for start in stride(from: 0, to: index.count, by: batchSize) {
                        continuation.yield(.nodesIndexed(min(batchSize, index.count - start)))
                    }
                    continuation.yield(.complete(index))
                } catch {
                    continuation.yield(.error(error))
                }
                continuation.finish()
            }
        }
    }
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

// MARK: - DocumentSource

/// A large XML, YAML or CSV file is indexed node by node, with keys and
/// values resolved at parse time, so its index can build any node.
extension StructuralIndex: DocumentSource {

    public var rootID: NodeID { entries.first?.id ?? NodeID(rawValue: 0) }

    public var nodeCount: Int { count }

    public func node(for id: NodeID, parent: DocumentNode?, internKeys: Bool) -> DocumentNode? {
        guard let entry = entry(for: id) else { return nil }
        let childIDs = (childIndices[id] ?? []).map { entries[$0].id }
        return makeDocumentNode(from: entry, childIDs: childIDs)
    }

    public func looksTabular() -> Bool { looksTabular(sampleSize: 10) }
}
