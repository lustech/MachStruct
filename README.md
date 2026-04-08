# MachStruct

> A native macOS structured-document viewer and editor built for speed.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/swift-5.10-orange)
![License](https://img.shields.io/badge/license-MIT-green)
![Tests](https://img.shields.io/badge/tests-332%20passing-brightgreen)

MachStruct opens, navigates, edits, and converts large JSON, XML, YAML, and CSV files in under a second. A 100 MB JSON file is structurally indexed in **under 500 ms** (release build) and displayed as a live, expandable, editable tree — no loading spinners, no frozen UI.

---

## Features

### Viewing
- **Full-text search** — Cmd+F searches all keys and scalar values; yellow highlights across the tree with amber active-match indicator and ↑↓ navigation counter in the toolbar; navigating to a match inside a collapsed subtree auto-expands the full ancestor chain and scrolls the row into view
- **Welcome screen** — drag files onto the drop zone, paste raw text directly, or pick from recents; no bare Open dialog on launch
- **Instant open** — simdjson SIMD parsing on a background actor; top-level nodes appear while the rest indexes
- **Zero-copy I/O** — memory-mapped files via `mmap`; a 100 MB file uses < 5 MB of resident memory while browsing
- **Lazy value parsing** — only nodes you expand are fully parsed
- **Progressive tree** — `AsyncStream` feeds the UI in batches so the tree is interactive before parsing finishes
- **Table view** — automatic spreadsheet grid for CSV files and uniform JSON/YAML arrays of objects
- **Raw text view** — toolbar toggle shows the full document as formatted text in a monospaced pane
- **Status bar** — live node count, file size, format label, and path to the selected node (`root.items[42].name`)

### Editing
- **Inline value editing** — click any scalar to edit; auto-detects type (null › bool › int › float › string)
- **Key renaming** — double-click a key label
- **Add / delete nodes** — context-menu "Add Key-Value", "Add Item", "Delete"
- **Array reordering** — Move Up / Move Down via context menu with full undo/redo
- **Copy / paste** — "Copy as JSON" for any subtree; "Paste from Clipboard" into containers
- **Unlimited undo/redo** — Cmd+Z / Cmd+Shift+Z via native `UndoManager`
- **Save** — Cmd+S round-trips correctly; window dirty dot appears on first edit

### Formats
- **JSON** — simdjson two-phase parse (structural index + lazy value decode)
- **XML** — libxml2 SAX parser; namespace badges, attribute display
- **YAML** — Yams/libyaml AST walk; anchor, scalar-style, and tag badges
- **CSV** — auto-delimiter detection (`,` `;` `\t` `|`); auto-header detection; RFC 4180 quoting
- **Auto-detection** — format sniffed from file content (first 512 bytes), not just extension
- **Export** — "Export as JSON / YAML / CSV…" toolbar menu with native save panel

---

## Requirements

| Dependency | Version |
|---|---|
| macOS | 14.0+ |
| Xcode | 15+ |
| simdjson | 3.12.3 (vendored — no install required) |
| Yams | 5.4+ (resolved automatically via SPM) |

No external dependencies to install. simdjson is bundled as a single-header amalgamation under `Sources/CSimdjsonBridge/vendor/`.

---

## Getting Started

### Open in Xcode (recommended)

```bash
git clone https://github.com/lustech/MachStruct.git
cd MachStruct
open MachStruct.xcodeproj
```

Press **⌘R** to build and run. The welcome window appears — drop any `.json`, `.xml`, `.yaml`, `.yml`, or `.csv` file onto the drop zone, paste raw structured text directly into the inline editor, or click "Open File…".

### Command line (library + tests only)

```bash
swift build -c release
swift test
```

> **Note:** `swift build` builds the core library and CLI. For the full macOS app (Dock icon, UTType registration, welcome window), open `MachStruct.xcodeproj` in Xcode.

The first test run generates ~120 MB of corpus files in `NSTemporaryDirectory()` and caches them for subsequent runs.

---

## Architecture

```
MachStruct/
├── Package.swift
├── MachStruct.xcodeproj          macOS app target (Info.plist, signing, assets)
├── Sources/
│   └── CSimdjsonBridge/          C++ DOM walker → flat MSIndexEntry[]
│       ├── include/MachStructBridge.h
│       ├── MachStructBridge.cpp
│       └── vendor/               simdjson 3.12.3 single-header amalgamation
│           ├── simdjson.h
│           └── simdjson.cpp
├── MachStruct/
│   ├── Assets.xcassets/          App icon (all macOS sizes)
│   ├── Core/                     MachStructCore library (no UI deps)
│   │   ├── Model/
│   │   │   ├── DocumentNode.swift    NodeID · NodeType · NodeValue · DocumentNode
│   │   │   ├── NodeIndex.swift       O(1) flat lookup + COW mutation + isTabular()
│   │   │   ├── ScalarValue.swift     Typed leaf values + parseScalarValue()
│   │   │   ├── EditTransaction.swift Reversible edit ops + factory methods
│   │   │   └── FormatMetadata.swift  Per-format annotations (XML/YAML/CSV metadata)
│   │   ├── FileIO/
│   │   │   └── MappedFile.swift      mmap wrapper with madvise hints
│   │   ├── Parsers/
│   │   │   ├── StructParser.swift    Protocol · IndexEntry · StructuralIndex · ParserRegistry
│   │   │   ├── JSONParser.swift      Two-phase parser (simdjson + Foundation)
│   │   │   ├── XMLParser.swift       libxml2 SAX parser
│   │   │   ├── YAMLParser.swift      Yams/libyaml AST walker
│   │   │   ├── CSVParser.swift       RFC 4180 + auto-delimiter/header detection
│   │   │   └── FormatDetector.swift  512-byte content sniffer (JSON/XML/YAML/CSV)
│   │   └── Serializers/
│   │       ├── JSONDocumentSerializer.swift  NodeIndex → JSON Data
│   │       ├── YAMLDocumentSerializer.swift  NodeIndex → YAML text (block style)
│   │       ├── CSVDocumentSerializer.swift   NodeIndex → RFC 4180 CSV (tabular only)
│   │       └── FormatConverter.swift         Unified convert(index:to:) entry point
│   └── App/                      MachStruct executable
│       ├── MachStructApp.swift     AppDelegate + MachStructDocumentController + DocumentGroup
│       ├── WelcomeView.swift       Launch window (drop zone, Open File, recent files)
│       ├── ContentView.swift       Tree / table / raw view switcher + toolbar
│       ├── MachStruct.entitlements App Sandbox + user-selected read-write
│       ├── Info.plist              UTType declarations, bundle ID, document types
│       ├── Document/
│       │   └── StructDocument.swift  ReferenceFileDocument; auto-detect format on open
│       └── UI/
│           ├── TreeView/
│           │   ├── TreeView.swift    SwiftUI List + OutlineGroup
│           │   ├── TreeNode.swift    Recursive data wrapper; format-specific badge helpers
│           │   ├── NodeRow.swift     Editing · move · copy/paste · XML/YAML badges
│           │   └── TypeBadge.swift   Colored capsule pills (str/int/bool/obj/arr/xml/yaml…)
│           ├── TableView/
│           │   └── TableView.swift   Sticky header + LazyVStack grid for tabular data
│           ├── Editing/
│           │   └── CommitEditEnvironment.swift  commitEdit / serializeNode env keys
│           └── Toolbar/
│               └── StatusBar.swift   Node count · file size · format name · node path
├── MachStructTests/
│   ├── ModelTests.swift              DocumentNode, COW, Sendable
│   ├── MappedFileTests.swift         mmap, slices, madvise
│   ├── SimdjsonBridgeTests.swift     C bridge, all scalar types
│   ├── JSONParserTests.swift         Foundation + simdjson paths
│   ├── XMLParserTests.swift          Elements, attributes, namespaces, CDATA
│   ├── YAMLParserTests.swift         Mappings, sequences, scalars, anchors, styles
│   ├── CSVParserTests.swift          RFC 4180, delimiter/header detection, CRLF
│   ├── TableViewTests.swift          isTabular(), tabularColumns
│   ├── EditTransactionTests.swift    All factory methods + undo
│   ├── JSONSerializerTests.swift     Round-trips, move, paste
│   ├── FormatConverterTests.swift    YAML/CSV serializers + cross-format round-trips
│   ├── FormatDetectorTests.swift     Content sniffing, BOM, extension fallback
│   ├── Generators/
│   │   └── TestCorpusGenerator.swift 7 corpus files, cached in tmp/
│   └── Performance/
│       └── ParseBenchmarks.swift     Hard timing assertions with os_signpost
├── .github/
│   └── workflows/
│       └── release.yml               CI: archive → notarize → staple → DMG → GitHub Release
└── scripts/
    └── README-signing.md             Certificate setup, archiving, notarization guide
```

### Two-Phase Parsing

```
File open
    │
    ▼
FormatDetector — probes first 512 bytes
    │   JSON ({/[) · XML (<) · YAML (---/key:) · CSV (delimiter consistency)
    │
    ▼
Phase 1 — Structural Index
    │   Format-specific parser scans the entire file and builds a flat
    │   [IndexEntry] — byte offsets, types, depths, parent IDs.
    │   No string or number values are parsed yet.
    │   Result: StructuralIndex → NodeIndex  (O(1) lookup by NodeID)
    │
    ▼
UI renders top-level tree (or table) immediately
    │
    ▼
Phase 2 — On-demand value parsing
        When a node becomes visible, its raw bytes are sliced from the
        memory-mapped region and parsed. For a 500K-node file the user
        typically touches fewer than 500 nodes.
```

### Performance (M1 Mac mini, release build)

| File | Size | Nodes | Index time |
|---|---|---|---|
| large.json | 10 MB | 210 K | **~115 ms** ✅ (target < 200 ms) |
| huge.json | 100 MB | 710 K | **< 500 ms** ✅ (target < 1 500 ms) |
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

### Phase 2 — Editor ✅
- [x] P2-01 Inline value editing (click scalar; Return commits, Escape cancels)
- [x] P2-02 Key renaming (double-click key label)
- [x] P2-03 Add / delete nodes (context-menu Add Key-Value, Add Item, Delete)
- [x] P2-04 Array reordering (Move Up / Move Down via context menu)
- [x] P2-05 `EditTransaction` + `UndoManager` (Cmd+Z / Cmd+Shift+Z)
- [x] P2-06 Save (`JSONDocumentSerializer` + `ReferenceFileDocument`)
- [x] P2-07 Dirty state UI (window edited dot; save dialog on close)
- [x] P2-08 Copy / paste nodes (Copy as JSON; Paste from Clipboard)
- [x] P2-09 Raw text view (toolbar toggle; async serialization)

### Phase 3 — Format Expansion ✅
- [x] P3-01 `XMLParser` (libxml2 SAX)
- [x] P3-02 XML UI — namespace badges, attribute display
- [x] P3-03 `YAMLParser` (Yams/libyaml)
- [x] P3-04 YAML UI — anchor, scalar-style, and tag badges
- [x] P3-05 `CSVParser` — auto-delimiter, auto-header, RFC 4180
- [x] P3-06 `TableView` — sticky header, virtualized `LazyVStack` rows
- [x] P3-07 Format conversion — `YAMLDocumentSerializer`, `CSVDocumentSerializer`, `FormatConverter`, export menu
- [x] P3-08 Auto-detection — `FormatDetector` content sniffer; `StructDocument` opens all four formats

### Phase 4 — Power Tools 🔄
- [x] P4-01 Full-text search — Cmd+F, keys + values, yellow/amber highlights, ↑↓ navigation
- [x] P4-02 Auto-expand on search nav — navigating to a match inside a collapsed subtree auto-expands ancestors and scrolls the row into view
- [ ] Path queries (JQ-style expressions)
- [ ] Diff view — compare two documents or two revisions
- [ ] Schema validation (JSON Schema, XSD/DTD)
- [ ] Format/minify — pretty-print or minify JSON/XML/YAML
- [ ] Syntax highlighting in raw text view (deferred from Phase 3)
- [ ] CSV column statistics — type distribution, unique count, min/max (deferred from Phase 3)
- [ ] Drag-and-drop reordering in tree view (deferred from Phase 2)
- [ ] Bookmarks and in-document navigation history
- [ ] Clipboard watch — detect structured data and offer to open

### Phase 5 — Release Engineering 🔄
- [x] P5-01 Vendor simdjson (bundled amalgamation v3.12.3 — no Homebrew required)
- [x] P5-02 Xcode app target + `Info.plist` UTType declarations
- [x] P5-03 App icon (`AppIcon.appiconset`, all required sizes)
- [x] P5-04 Code signing (entitlements, `ExportOptions-Direct.plist`, `ExportOptions-AppStore.plist`, Hardened Runtime)
- [x] P5-05 Notarization + GitHub Actions release pipeline → notarized DMG on tag push
- [ ] P5-06 Sparkle 2 auto-updates (appcast, EdDSA signing, background update check)
- [ ] P5-07 App Store submission prep (screenshots, listing copy, `xcrun altool` validation)

### Phase 6 — Polish 🔄
- [x] P6-02 Welcome / launch window (drop zone, Open File button, recent files list)
- [x] P6-03 Paste raw text on welcome screen (inline TextEditor, auto-detect format, opens as untitled doc)
- [ ] Settings UI (theme, font size, keyboard shortcut customisation)
- [ ] Quick Look plugin
- [ ] Spotlight importer
- [ ] Accessibility audit (VoiceOver, keyboard-only navigation)
- [ ] Localisation (en, de, fr, ja)

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
| [`docs/roadmap/ROADMAP.md`](docs/roadmap/ROADMAP.md) | Full phase breakdown with implementation notes |
| [`docs/tasks/TASK-INDEX.md`](docs/tasks/TASK-INDEX.md) | AI-agent task breakdown with acceptance criteria |
| [`scripts/README-signing.md`](scripts/README-signing.md) | Certificate setup, archiving, notarization guide |
| [`.github/workflows/release.yml`](.github/workflows/release.yml) | CI release pipeline: notarize → DMG → GitHub Release |

---

## License

MIT © 2026 lustech
