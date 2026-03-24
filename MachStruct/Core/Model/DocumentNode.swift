import Foundation

// MARK: - NodeID

/// Stable, unique identifier for every node in a document.
/// Uses a monotonically increasing counter per document session.
public struct NodeID: Hashable, Sendable, Identifiable {
    public let rawValue: UInt64
    public var id: UInt64 { rawValue }

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Generate a new unique NodeID. Thread-safe.
    public static func generate() -> NodeID {
        NodeID(rawValue: _nodeIDSource.next())
    }
}

private final class _NodeIDSource {
    private var counter: UInt64 = 0
    private let lock = NSLock()

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return counter
    }
}

private let _nodeIDSource = _NodeIDSource()

// MARK: - NodeType

/// The structural role of a node in the document tree.
public enum NodeType: UInt8, Sendable, Equatable {
    case object    // JSON object, XML element, YAML mapping
    case array     // JSON array, YAML sequence, CSV row-set
    case keyValue  // A key-value pair within an object
    case scalar    // String, number, boolean, null — leaf value
}

// MARK: - NodeValue

/// The value state of a node. Lazy by default — most nodes start as `.unparsed`.
public enum NodeValue: Sendable, Equatable {
    case unparsed                       // Not yet read from file
    case scalar(ScalarValue)            // Fully parsed leaf value
    case container(childCount: Int)     // Object or array; value is its children
    case error(String)                  // Parse error for this specific node
}

// MARK: - SourceRange

/// Points back to the exact bytes in the source file for this node.
public struct SourceRange: Sendable, Equatable {
    public let byteOffset: UInt64
    public let byteLength: UInt32

    public init(byteOffset: UInt64, byteLength: UInt32) {
        self.byteOffset = byteOffset
        self.byteLength = byteLength
    }

    /// Sentinel for nodes with no known source location.
    public static let unknown = SourceRange(byteOffset: 0, byteLength: 0)
}

// MARK: - DocumentNode

/// The universal node type. Every node in every format maps to this.
/// Uses value semantics — mutations produce independent copies (COW via NodeIndex dictionary).
public struct DocumentNode: Identifiable, Sendable {
    public let id: NodeID
    public let type: NodeType
    public let depth: UInt16

    // Structural relationships
    public var parentID: NodeID?
    public var childIDs: [NodeID]

    /// Key for this node: object key name, XML attribute name, CSV column header,
    /// or string-encoded array index for positional children.
    public var key: String?

    /// Value state — lazily populated from the source file.
    public var value: NodeValue

    /// Byte location in the original file.
    public var sourceRange: SourceRange

    /// Format-specific extra info (namespace, anchors, CSV delimiter, etc.).
    public var metadata: FormatMetadata?

    public init(
        id: NodeID = .generate(),
        type: NodeType,
        depth: UInt16 = 0,
        parentID: NodeID? = nil,
        childIDs: [NodeID] = [],
        key: String? = nil,
        value: NodeValue = .unparsed,
        sourceRange: SourceRange = .unknown,
        metadata: FormatMetadata? = nil
    ) {
        self.id = id
        self.type = type
        self.depth = depth
        self.parentID = parentID
        self.childIDs = childIDs
        self.key = key
        self.value = value
        self.sourceRange = sourceRange
        self.metadata = metadata
    }
}
