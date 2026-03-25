# MachStruct

> A native macOS structured-document viewer built for speed.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/swift-5.10-orange)
![License](https://img.shields.io/badge/license-MIT-green)
![Tests](https://img.shields.io/badge/tests-87%20passing-brightgreen)

MachStruct opens large JSON files (and eventually XML, YAML, CSV) in under a second and lets you navigate the tree without lag. A 100 MB JSON file is structurally indexed in **~430 ms** and displayed as a live, expandable tree — no loading spinners, no frozen UI.

---

## Features

- **Instant open** — simdjson SIMD parsing on a background actor; top-level nodes appear while the rest indexes
- **Zero-copy I/O** — memory-mapped files via `mmap`; a 100 MB file uses < 5 MB of resident memory while browsing
- **Lazy value parsing** — only nodes you actually expand are fully parsed
- **Progressive tree** — `AsyncStream` feeds the UI in batches of 1 000 nodes
- **Status bar** — live node count, file size, format label, and path to the selected node
- **Native feel** — SwiftUI `DocumentGroup`, `List` with `OutlineGroup`, keyboard navigation, macOS 14+ design language
- **87 tests** — unit tests for every layer plus a benchmark suite with hard timing assertions

---

## Requirements

| Dependency | Version |
|---|---|
| macOS | 14.0+ |
| Xcode | 15+ (or Swift 5.10 toolchain) |
| simdjson | 4.x (via Homebrew) |

Install simdjson:

```bash
brew install simdjson
```

---

## Getting Started

### Open in Xcode (recommended)

```bash
git clone https://github.com/lustech/MachStruct.git
cd MachStruct
open Package.swift
```

Press **⌘R** to build and run. An Open dialog appears — pick any `.json` file.

### Command line

```bash
swift build -c release
```

Then run the binary and use **File → Open** (⌘O) to open a JSON file.

### Run tests

```bash
swift test
```

The first run generates ~120 MB of test-corpus files in `NSTemporaryDirectory()` and caches them for subsequent runs.

---

## Architecture

```
MachStruct/
├── Package.swift
├── Sources/
│   ├── CSystemSimdjson/           SPM systemLibrary → Homebrew simdjson
│   └── CSimdjsonBridge/           C++ DOM walker → flat MSIndexEntry[]
│       ├── include/MachStructBridge.h
│       └── MachStructBridge.cpp
├── MachStruct/
│   ├── Core/                      MachStructCore library (no UI deps)
│   │   ├── Model/
│   │   │   ├── DocumentNode.swift    NodeID · NodeType · NodeValue · DocumentNode
│   │   │   ├── NodeIndex.swift       O(1) flat lookup + COW mutation API
│   │   │   ├── ScalarValue.swift     Typed leaf values with display helpers
│   │   │   └── FormatMetadata.swift  Per-format annotations
│   │   ├── FileIO/
│   │   │   └── MappedFile.swift      mmap wrapper with madvise hints
│   │   └── Parsers/
│   │       ├── StructParser.swift    Protocol · IndexEntry · StructuralIndex
│   │       └── JSONParser.swift      Two-phase parser (simdjson + Foundation)
│   └── App/                       MachStruct executable
│       ├── MachStructApp.swift       DocumentGroup scene
│       ├── ContentView.swift         Loading / error / tree switcher
│       ├── Document/
│       │   └── StructDocument.swift  ReferenceFileDocument + async load
│       └── UI/
│           ├── TreeView/
│           │   ├── TreeView.swift    SwiftUI List + OutlineGroup
│           │   ├── TreeNode.swift    Recursive data wrapper for List
│           │   ├── NodeRow.swift     Key · value · type badge row
│           │   └── TypeBadge.swift   Colored capsule pill
│           └── Toolbar/
│               └── StatusBar.swift   Node count · file size · path
└── MachStructTests/
    ├── ModelTests.swift              26 tests — NodeID, COW, Sendable
    ├── MappedFileTests.swift         10 tests — mmap, slices, madvise
    ├── SimdjsonBridgeTests.swift     13 tests — C bridge, all scalar types
    ├── JSONParserTests.swift         27 tests — Foundation + simdjson paths
    ├── Generators/
    │   └── TestCorpusGenerator.swift 7 corpus files, cached in tmp/
    └── Performance/
        └── ParseBenchmarks.swift     17 benchmarks with os_signpost
```

### Two-Phase Parsing

```
File open
    │
    ▼
Phase 1 — Structural Index
    │   simdjson (≥ 5 MB) or Foundation (< 5 MB) scans the entire file
    │   and builds a flat [IndexEntry] — byte offsets, types, depths,
    │   parent IDs. No string or number values are parsed yet.
    │   Result: StructuralIndex → NodeIndex  (O(1) lookup by NodeID)
    │
    ▼
UI renders top-level tree immediately
    │
    ▼
Phase 2 — On-demand value parsing
    │   When a node becomes visible, its raw bytes are sliced from the
    │   memory-mapped region and parsed by Foundation. For a 500K-node
    │   file the user typically parses fewer than 500 nodes.
    ▼
```

### Performance (M1 Mac mini, debug build)

| File | Size | Nodes | Index time |
|---|---|---|---|
| large.json | 10 MB | 210 K | **~115 ms** ✅ (target < 200 ms) |
| huge.json | 100 MB | 710 K | **~430 ms** ✅ (target < 1 500 ms) |
| pathological_wide | 10 MB | 350 K | ~180 ms |
| pathological_deep | — | depth 401 | ~17 ms |

---

## Roadmap

### Phase 1 — Foundation ✅
- [x] P1-01 Project scaffold (SwiftUI `DocumentGroup`, SPM)
- [x] P1-02 `MappedFile` (mmap, madvise, zero-copy slices)
- [x] P1-03 simdjson C bridge
- [x] P1-04 Core data model (`NodeID`, `NodeIndex`, COW, `Sendable`)
- [x] P1-05 `StructParser` protocol + `ParserRegistry`
- [x] P1-06 `JSONParser` (two-phase, progressive `AsyncStream`)
- [x] P1-07 `StructDocument` (`ReferenceFileDocument`)
- [x] P1-08 `TreeView` (SwiftUI `List` + `OutlineGroup`, lazy expansion)
- [x] P1-09 Status bar (node count, file size, format, selected path)
- [x] P1-10 Benchmark suite (corpus generator + hard timing assertions)

### Phase 2 — Editor 🚧
- [ ] P2-01 Inline value editing
- [ ] P2-02 Key renaming
- [ ] P2-03 Add / delete nodes
- [ ] P2-04 Array reordering (drag-and-drop)
- [ ] P2-05 `EditTransaction` + `UndoManager`
- [ ] P2-06 Incremental save
- [ ] P2-07 Dirty state UI
- [ ] P2-08 Copy / paste nodes
- [ ] P2-09 Raw text view

### Phase 3 — Format Expansion
- [ ] P3-01 XMLParser (libxml2 SAX)
- [ ] P3-02 YAMLParser (libyaml)
- [ ] P3-03 CSVParser
- [ ] P3-04 Table view for uniform arrays
- [ ] P3-05 Format conversion
- [ ] P3-06 Content-based auto-detection

---

## Contributing

1. Fork the repo and create a feature branch
2. Add tests alongside your code — every module has a corresponding test file
3. Run `swift test` and confirm all tests pass before opening a PR
4. Follow the existing conventions:
   - **Actors** for parser/registry state
   - **`nonisolated`** for stateless helpers that don't access actor storage
   - **COW structs** for all model types (`NodeIndex`, `DocumentNode`)
   - **`Sendable`** conformance on everything that crosses concurrency boundaries

See [`docs/`](docs/) for the full design documentation:

| Doc | Contents |
|---|---|
| [`docs/design/DATA-MODEL.md`](docs/design/DATA-MODEL.md) | Node types, COW semantics, NodeIndex API |
| [`docs/design/PARSING-ENGINE.md`](docs/design/PARSING-ENGINE.md) | Two-phase strategy, simdjson integration |
| [`docs/design/UI-DESIGN.md`](docs/design/UI-DESIGN.md) | Window layout, tree view, keyboard shortcuts |
| [`docs/design/PERFORMANCE.md`](docs/design/PERFORMANCE.md) | Targets, measurement plan, optimization notes |
| [`docs/roadmap/ROADMAP.md`](docs/roadmap/ROADMAP.md) | Full phase breakdown |

---

## License

MIT © 2025 lustech
