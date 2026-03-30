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
/// Convert to a fully navigable `NodeIndex` via `buildNodeIndex()`.
public struct StructuralIndex: Sendable {

    public let entries: [IndexEntry]
    public var count: Int { entries.count }

    public init(entries: [IndexEntry]) {
        self.entries = entries
    }

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

        var nodes = [NodeID: DocumentNode](minimumCapacity: entries.count)
        var childIDsByParent = [NodeID: [NodeID]]()
        childIDsByParent.reserveCapacity(entries.count / 2)

        for entry in entries {
            let value: NodeValue
            switch entry.nodeType {
            case .object, .array:
                value = .container(childCount: Int(entry.childCount))
            case .scalar:
                value = entry.parsedValue.map { .scalar($0) } ?? .unparsed
            case .keyValue:
                value = .unparsed   // the actual value lives in the child node
            }

            nodes[entry.id] = DocumentNode(
                id: entry.id,
                type: entry.nodeType,
                depth: entry.depth,
                parentID: entry.parentID,
                childIDs: [],
                key: entry.key,
                value: value,
                sourceRange: SourceRange(byteOffset: entry.byteOffset,
                                         byteLength: entry.byteLength),
                metadata: entry.metadata
            )

            if let pid = entry.parentID {
                childIDsByParent[pid, default: []].append(entry.id)
            }
        }

        // Wire up childIDs (entries are in document order so children appear after parents)
        for (pid, children) in childIDsByParent {
            guard var node = nodes[pid] else { continue }
            node.childIDs = children
            nodes[pid] = node
        }

        return NodeIndex(rootID: first.id, allNodes: nodes)
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
