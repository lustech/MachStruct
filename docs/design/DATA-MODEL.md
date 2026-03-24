# Data Model Design

> The format-agnostic internal representation that all of MachStruct builds upon.

## 1. Design Principles

- **One model for all formats.** JSON objects, XML elements, YAML mappings, and CSV rows all map to the same node tree. UI code never knows what format it's displaying.
- **Identity stability.** Every node has a stable ID that survives edits, re-parses, and undo/redo. SwiftUI diffing depends on this.
- **Minimal memory.** Nodes store metadata and byte references, not materialized values, until explicitly needed.
- **Copy-on-write.** The node tree is a value type using Swift's COW semantics. Edits create cheap snapshots for undo.

## 2. Core Types

### NodeID
```swift
/// Stable, unique identifier for every node in a document.
/// Uses a monotonically increasing counter per document session.
struct NodeID: Hashable, Sendable, Identifiable {
    let rawValue: UInt64
    var id: UInt64 { rawValue }
}
```

### NodeType
```swift
enum NodeType: UInt8, Sendable {
    case object     // JSON object, XML element, YAML mapping
    case array      // JSON array, YAML sequence, CSV row-set
    case keyValue   // A key-value pair within an object
    case scalar     // String, number, boolean, null — leaf values
}
```

### ScalarValue
```swift
/// A fully parsed leaf value.
enum ScalarValue: Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case boolean(Bool)
    case null

    /// Display string for the UI tree
    var displayText: String { ... }

    /// Type badge text ("str", "int", "num", "bool", "null")
    var typeBadge: String { ... }
}
```

### DocumentNode
```swift
/// The universal node type. Every node in every format maps to this.
struct DocumentNode: Identifiable, Sendable {
    let id: NodeID
    let type: NodeType
    let depth: UInt16

    // Structural relationships
    var parentID: NodeID?
    var childIDs: [NodeID]          // Ordered list of children

    // Key (for key-value pairs inside objects)
    var key: String?                // "name", "items[0]", XML attribute name, CSV column header

    // Value — lazily populated
    var value: NodeValue            // See below

    // Source location — for jumping to raw text
    var sourceRange: SourceRange    // byte offset + length in original file

    // Format-specific metadata (optional)
    var metadata: FormatMetadata?
}
```

### NodeValue
```swift
/// Represents the value state of a node. Lazy by default.
enum NodeValue: Sendable {
    case unparsed                           // Not yet read from file — the default state
    case scalar(ScalarValue)                // Fully parsed leaf value
    case container(childCount: Int)         // Object or array — value is its children
    case error(String)                      // Parse error for this specific node
}
```

### SourceRange
```swift
/// Points back to the exact bytes in the source file for this node.
struct SourceRange: Sendable {
    let byteOffset: UInt64
    let byteLength: UInt32
}
```

### FormatMetadata
```swift
/// Optional format-specific info that doesn't fit the universal model.
enum FormatMetadata: Sendable {
    case json(JSONMetadata)
    case xml(XMLMetadata)
    case yaml(YAMLMetadata)
    case csv(CSVMetadata)
}

struct JSONMetadata: Sendable {
    var hasTrailingComma: Bool
    var hasComments: Bool
}

struct XMLMetadata: Sendable {
    var namespace: String?
    var attributes: [(key: String, value: String)]
    var isSelfClosing: Bool
}

struct YAMLMetadata: Sendable {
    var anchor: String?         // &anchor
    var alias: String?          // *alias
    var tag: String?            // !tag
    var scalarStyle: YAMLScalarStyle  // literal, folded, quoted, etc.
}

struct CSVMetadata: Sendable {
    var delimiter: Character    // comma, tab, semicolon, pipe
    var hasHeader: Bool
    var columnIndex: Int
}
```

## 3. The NodeIndex — Fast Lookup

The `NodeIndex` is a flat dictionary that enables O(1) access to any node by ID and fast path-based queries.

```swift
struct NodeIndex: Sendable {
    /// O(1) lookup by ID
    private var nodesById: [NodeID: DocumentNode]

    /// Root node ID
    let rootID: NodeID

    /// Total node count
    var count: Int { nodesById.count }

    // --- Query API ---

    func node(for id: NodeID) -> DocumentNode?
    func children(of id: NodeID) -> [DocumentNode]
    func parent(of id: NodeID) -> DocumentNode?
    func path(to id: NodeID) -> [NodeID]              // Ancestors from root to node
    func pathString(to id: NodeID) -> String           // "root.items[3].name"

    // --- Search ---

    func nodesMatching(predicate: (DocumentNode) -> Bool) -> [DocumentNode]
    func nodesAtDepth(_ depth: Int) -> [DocumentNode]

    // --- Mutation (returns new index via COW) ---

    mutating func updateNode(_ id: NodeID, transform: (inout DocumentNode) -> Void)
    mutating func insertChild(_ node: DocumentNode, in parent: NodeID, at index: Int)
    mutating func removeNode(_ id: NodeID)
}
```

### Memory Budget

For a 100MB JSON file with ~500K nodes, the `NodeIndex` consumes approximately:
- `DocumentNode` struct ≈ 80 bytes × 500K = **40MB**
- Dictionary overhead ≈ 16 bytes × 500K = **8MB**
- Total: **~48MB** — acceptable for a desktop app.

If this proves too large, we can tier the index: keep only depth-0 and depth-1 nodes in memory and load deeper subtrees on demand.

## 4. Format Mapping Rules

### JSON → DocumentNode

| JSON | NodeType | Key | Value |
|---|---|---|---|
| `{ }` | `.object` | — | `.container(childCount: N)` |
| `[ ]` | `.array` | — | `.container(childCount: N)` |
| `"key": value` | `.keyValue` | `"key"` | delegates to child |
| `"text"` | `.scalar` | — | `.scalar(.string("text"))` |
| `42` | `.scalar` | — | `.scalar(.integer(42))` |
| `3.14` | `.scalar` | — | `.scalar(.float(3.14))` |
| `true/false` | `.scalar` | — | `.scalar(.boolean(...))` |
| `null` | `.scalar` | — | `.scalar(.null)` |

### XML → DocumentNode

| XML | NodeType | Key | Metadata |
|---|---|---|---|
| `<element>` | `.object` | tag name | XMLMetadata with namespace, attributes |
| Text content | `.scalar` | — | `.scalar(.string(...))` |
| Attributes | `.keyValue` per attribute | attr name | Stored in XMLMetadata and as child keyValue nodes |

### YAML → DocumentNode

YAML maps almost identically to JSON. Special handling for anchors (create reference nodes) and multi-line strings (preserve style in YAMLMetadata).

### CSV → DocumentNode

| CSV | NodeType | Key | Notes |
|---|---|---|---|
| Entire file | `.array` | — | Top-level container |
| Each row | `.object` | Row index / first column | Children are cells |
| Each cell | `.scalar` | Column header | `.scalar(.string(...))` |

## 5. Edit Transactions and Undo

Edits are captured as reversible transactions:

```swift
struct EditTransaction: Sendable {
    let id: UUID
    let timestamp: Date
    let description: String       // "Changed value of root.name"

    let affectedNodeIDs: Set<NodeID>
    let beforeSnapshot: [NodeID: DocumentNode]
    let afterSnapshot: [NodeID: DocumentNode]

    func undo(index: inout NodeIndex) { ... }
    func redo(index: inout NodeIndex) { ... }
}
```

The `StructDocument` (NSDocument subclass) manages an undo stack of these transactions and registers them with the system UndoManager for native Cmd+Z support.

## 6. Serialization Back to Disk

When saving, we reconstruct the file from the node tree. The relevant `StructParser` handles serialization:

- **Unmodified regions:** Copy raw bytes from the original mmap'd file (zero-cost).
- **Modified nodes:** Serialize via `parser.serialize(value:)` and splice into the output.
- **Formatting preservation:** Store original indentation/whitespace style and reproduce it for unmodified nodes. Offer "reformat on save" as an option.

This hybrid approach means saving a file where only one value changed is nearly instant, even for 100MB files — we only rewrite the changed region.
