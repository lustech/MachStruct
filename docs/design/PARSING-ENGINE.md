# Parsing Engine Design

> How MachStruct reads structured documents at maximum speed.

## 1. Design Goals

- Open a 100MB JSON file in under 1 second (structural index ready, top-level nodes visible).
- Never block the main thread during parsing.
- Support progressive rendering — show parsed content as it becomes available.
- Provide a clean `StructParser` protocol that makes adding XML/YAML/CSV straightforward.

## 2. Two-Phase Parsing Strategy

MachStruct uses a **two-phase approach** to achieve perceived-instant file opening:

### Phase 1: Structural Indexing (fast, background)
Scan the entire file to build a **structural index** — a compact map of every node's byte offset, type, depth, and parent relationship. This phase does NOT parse string values, numbers, or any content — it only identifies structural boundaries (braces, brackets, colons, commas for JSON).

**Output:** `StructuralIndex` — an array of `IndexEntry` structs:
```swift
struct IndexEntry {
    let id: NodeID              // Unique, stable identifier
    let byteOffset: UInt64      // Start position in file
    let byteLength: UInt32      // Length of this node's raw bytes
    let nodeType: NodeType      // .object, .array, .string, .number, .bool, .null
    let depth: UInt16           // Nesting depth
    let parentID: NodeID?       // Parent node reference
    let childCount: UInt32      // Number of direct children (for objects/arrays)
}
```

**Performance target:** ~500MB/s on Apple Silicon (simdjson's structural scanning speed).

### Phase 2: On-Demand Value Parsing (lazy, per-node)
When a node becomes visible in the UI (expanded in the tree, selected for editing, matched by search), we parse its actual value from the raw bytes using the byte offset from the structural index. This is a trivial seek + parse of a small slice.

**Key insight:** For a 100MB JSON file with 500K nodes, the user might only ever look at a few hundred. We parse only what's needed.

## 3. File I/O: Memory-Mapped Access

```swift
final class MappedFile: Sendable {
    let data: UnsafeRawBufferPointer  // mmap'd region
    let fileSize: UInt64

    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        // mmap with MAP_PRIVATE | MAP_NORESERVE
        // advise sequential access for indexing: madvise(MADV_SEQUENTIAL)
        // advise random access for value parsing: madvise(MADV_RANDOM)
    }

    func slice(offset: UInt64, length: UInt32) -> UnsafeRawBufferPointer {
        // Zero-copy slice into the mapped region
    }

    deinit {
        munmap(...)
    }
}
```

**Why mmap?** The OS manages paging — only the pages we actually touch get loaded into physical memory. A 100MB file might only use 2–5MB of resident memory if the user browses a small portion.

**madvise strategy:**
- During Phase 1 (indexing): `MADV_SEQUENTIAL` — we scan front to back.
- During Phase 2 (value parsing): `MADV_RANDOM` — we jump to arbitrary offsets.

## 4. simdjson Integration

simdjson is a C++ library that uses SIMD instructions (NEON on Apple Silicon) to parse JSON at hardware speed. We use it specifically for Phase 1 structural indexing.

### C Bridge
```c
// MachStructBridge.h
typedef struct {
    uint64_t byte_offset;
    uint32_t byte_length;
    uint8_t  node_type;    // 0=object, 1=array, 2=string, 3=number, 4=bool, 5=null
    uint16_t depth;
    int64_t  parent_index; // -1 if root
    uint32_t child_count;
} MSIndexEntry;

// Returns number of entries written, or negative error code
int64_t ms_build_structural_index(
    const char* data,
    uint64_t length,
    MSIndexEntry* out_entries,
    uint64_t max_entries
);
```

### Swift Wrapper
```swift
actor JSONParser: StructParser {
    func buildIndex(from file: MappedFile) async throws -> StructuralIndex {
        // Allocate output buffer
        let maxEntries = file.fileSize / 4  // conservative estimate
        let entries = UnsafeMutableBufferPointer<MSIndexEntry>.allocate(capacity: Int(maxEntries))
        defer { entries.deallocate() }

        let count = ms_build_structural_index(
            file.data.baseAddress,
            file.fileSize,
            entries.baseAddress,
            maxEntries
        )

        guard count >= 0 else { throw ParseError.structuralError(code: count) }

        return StructuralIndex(entries: entries, count: Int(count))
    }
}
```

### Fallback Path
For files under 5MB, or when simdjson is unavailable, use Foundation's `JSONSerialization` as a single-pass parser that produces both index and values. This is simpler and avoids the C bridge overhead for small files.

## 5. The StructParser Protocol

Every format implements this protocol. This is the sole extension point for new formats.

```swift
protocol StructParser: Sendable {
    /// The file extensions this parser handles
    static var supportedExtensions: Set<String> { get }

    /// Build a structural index from raw file data.
    /// This must be fast — no value parsing, just structure.
    func buildIndex(from file: MappedFile) async throws -> StructuralIndex

    /// Parse the actual value of a single node, given its index entry.
    /// Called lazily when a node becomes visible.
    func parseValue(entry: IndexEntry, from file: MappedFile) throws -> NodeValue

    /// Serialize a modified node value back to the format's text representation.
    func serialize(value: NodeValue) throws -> Data

    /// Validate the entire file (optional, for background validation).
    func validate(file: MappedFile) async throws -> [ValidationIssue]
}
```

### Format Implementations Planned

| Format | Parser Class | Phase 1 Strategy | Notes |
|---|---|---|---|
| JSON | `JSONParser` | simdjson structural scan | Primary format. C-interop for speed. |
| XML | `XMLParser` | libxml2 SAX streaming | SAX events map naturally to structural index entries. Apple ships libxml2 with macOS. |
| YAML | `YAMLParser` | libyaml event-based | Similar SAX-like event model. Handle anchors/aliases as references. |
| CSV | `CSVParser` | Custom line scanner | CSV is flat — rows and columns map to a two-level tree. Detect delimiters automatically. |

## 6. Progressive Parsing and Streaming

For the best user experience, parsing streams results to the UI:

```swift
actor JSONParser {
    func parseProgressively(file: MappedFile) -> AsyncStream<ParseProgress> {
        AsyncStream { continuation in
            // Emit progress updates every ~10ms or every 1000 nodes
            // UI can render the tree as it grows
            for batch in indexBatches {
                continuation.yield(.nodesIndexed(batch))
            }
            continuation.yield(.complete(index))
            continuation.finish()
        }
    }
}

enum ParseProgress {
    case nodesIndexed([IndexEntry])  // Batch of newly indexed nodes
    case complete(StructuralIndex)   // All done
    case error(ParseError)           // Something went wrong
}
```

The UI subscribes to this stream and renders nodes as they arrive. The top of the tree appears almost instantly even for very large files.

## 7. Error Handling and Recovery

Structured documents in the wild are often malformed. MachStruct should be resilient:

- **Trailing commas** in JSON — accept them (common in config files).
- **Comments** in JSON — accept `//` and `/* */` style (JSONC format).
- **Truncated files** — parse what we can, mark the truncation point.
- **Encoding detection** — try UTF-8 first, fall back to UTF-16/Latin-1 with a warning.
- **Mixed line endings** — normalize internally, preserve on save.

Validation issues are collected but don't block rendering. The user sees a warning badge and can view the list of issues.

## 8. Key Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| simdjson C-interop complexity | Build issues, maintenance burden | Keep the bridge minimal (~200 lines of C). Fall back to Foundation for small files. |
| Structural index memory for huge files | 100MB file ≈ 500K nodes ≈ 20MB index | Acceptable. For files >500MB, consider a disk-backed index (future). |
| YAML complexity (anchors, tags, multiline) | Parser edge cases | Use libyaml which handles the full spec. Map anchors to reference nodes. |
| Malformed files crashing the parser | Bad UX | Defensive parsing with try/catch at every level. Never crash — always show what we can. |
