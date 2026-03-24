# Performance Strategy

> Concrete targets, measurement plan, and optimization techniques.

## 1. Performance Targets

These are the numbers MachStruct must hit to feel "superfast." All measured on an M1 MacBook Air (base model) as the performance floor.

| Operation | Target (10MB file) | Target (100MB file) |
|---|---|---|
| **File open → first nodes visible** | < 100ms | < 500ms |
| **File open → full structural index** | < 200ms | < 1.5s |
| **Tree node expand** (100 children) | < 16ms (1 frame) | < 16ms |
| **Tree scroll** (smooth 60fps) | 0 dropped frames | 0 dropped frames |
| **Search** (full-text, 500K nodes) | < 200ms | < 1s |
| **Edit single value** (commit) | < 16ms | < 16ms |
| **Save file** (1 value changed) | < 100ms | < 500ms |
| **Memory usage** (browsing, not editing) | < 50MB resident | < 150MB resident |
| **App launch → ready** | < 500ms | — |

## 2. Benchmarking Plan

### Test Corpus
Maintain a set of standardized test files in the repo:

| File | Size | Characteristics |
|---|---|---|
| `tiny.json` | 1KB | Simple nested object |
| `medium.json` | 1MB | 5K nodes, mixed types |
| `large.json` | 10MB | 50K nodes, deep nesting (depth 20+) |
| `huge.json` | 100MB | 500K nodes, wide arrays (10K+ items) |
| `pathological_deep.json` | 5MB | Depth 500+, stress test for recursion |
| `pathological_wide.json` | 50MB | Single array with 1M simple items |
| `malformed.json` | 10MB | Trailing commas, comments, truncated |

Generate these programmatically with a script in `MachStructTests/Generators/`.

### Measurement Framework
```swift
/// Use os_signpost for Instruments integration
import os

let perfLog = OSLog(subsystem: "com.machstruct", category: .pointsOfInterest)

func benchmarkParse(file: URL) {
    os_signpost(.begin, log: perfLog, name: "Parse", "%{public}s", file.lastPathComponent)
    // ... parsing ...
    os_signpost(.end, log: perfLog, name: "Parse")
}
```

Integrate with `XCTest.measure {}` for automated regression tracking:
```swift
func testLargeFileParse() {
    let file = testBundle.url(forResource: "large", withExtension: "json")!
    measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
        let index = try! parser.buildIndex(from: MappedFile(url: file))
        XCTAssert(index.count > 0)
    }
}
```

Run benchmarks on every PR via CI. Track trends over time.

## 3. Optimization Techniques

### 3.1 Memory-Mapped I/O
See PARSING-ENGINE.md. The core insight: `mmap` lets the OS manage which pages are in physical memory. We never allocate a 100MB buffer.

### 3.2 Lazy Value Parsing
The structural index stores byte offsets but NOT parsed values. Values are parsed on-demand when nodes become visible. For a 500K-node file where the user views ~200 nodes, this avoids 99.96% of parsing work.

### 3.3 View Recycling
SwiftUI `List` automatically recycles row views. A list showing 50 visible rows only maintains ~60–70 view instances regardless of the total item count. Combined with `OutlineGroup` (which only creates children when expanded), this keeps the view layer ultra-lean.

### 3.4 Background Indexing
Structural indexing runs on a background actor. The UI receives progressive updates via `AsyncStream` and renders the tree as it grows. The user never waits for indexing to complete before interacting.

### 3.5 Incremental Save
When saving after an edit, only the modified byte ranges are rewritten. Unmodified regions are copied directly from the mmap'd source. For a single value change in a 100MB file, this means writing ~100MB but doing zero parsing — essentially a memcpy with a small splice.

### 3.6 Search Optimization
- **Key search** queries against a pre-built key string table (deduped, since many nodes share the same key names).
- **Value search** uses the structural index to skip non-matching node types (searching for a number? Skip all string/object/array nodes).
- **Path queries** traverse the index tree directly without touching values.

### 3.7 String Interning
Many JSON documents have repetitive keys ("id", "name", "type", "value"). Intern these strings to save memory and speed up comparisons:
```swift
actor StringInterner {
    private var table: [String: String] = [:]
    func intern(_ s: String) -> String {
        if let existing = table[s] { return existing }
        table[s] = s
        return s
    }
}
```

### 3.8 Batch UI Updates
When expanding a node with 10K children, don't emit 10K individual SwiftUI updates. Batch into chunks of ~500 and yield between batches to keep the UI responsive:
```swift
for batch in children.chunked(into: 500) {
    appendChildren(batch)
    await Task.yield()  // Let the UI render
}
```

## 4. Memory Budget

Target peak memory usage for different file sizes:

| File Size | Structural Index | NodeIndex | UI Layer | Total Target |
|---|---|---|---|---|
| 1MB | ~200KB | ~2MB | ~5MB | < 30MB |
| 10MB | ~2MB | ~20MB | ~5MB | < 50MB |
| 100MB | ~20MB | ~48MB | ~5MB | < 150MB |

If memory pressure is detected (via `os_proc_available_memory`), shed non-visible parsed values and deeper index entries.

## 5. Startup Performance

App launch must be fast. Key tactics:
- Minimal work in `App.init()`. No eager resource loading.
- File association opens directly to parsing — no splash screen or empty state delay.
- Precompile SwiftUI views by keeping the view hierarchy shallow at launch.
- Use `@StateObject` (not `@ObservedObject`) for document state to avoid redundant init.

## 6. Profiling Toolkit

Instruments templates to create and maintain:
- **MachStruct Parse** — Time Profile + os_signpost focused on parsing and indexing.
- **MachStruct Memory** — Allocations + Leaks + VM Tracker for memory characterization.
- **MachStruct UI** — SwiftUI instrument + Core Animation for frame drops and view lifecycle.

Document profiling steps so any developer can reproduce performance measurements.
