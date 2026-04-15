# MachStruct

> A native macOS structured-document viewer and editor built for speed.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/swift-5.10-orange)
![License](https://img.shields.io/badge/license-MIT-green)
![Tests](https://img.shields.io/badge/tests-332%20passing-brightgreen)

MachStruct opens, navigates, edits, and converts large JSON, XML, YAML, and CSV files in under a second. A 100 MB JSON file is structurally indexed in **under 500 ms** (release build) and displayed as a live, expandable, editable tree — no loading spinners, no frozen UI.

---

## Features

### Viewing & Navigation
- **Full-text search** — Cmd+F; yellow highlights on all matches, amber on the active one; ↑↓ navigation counter; navigating to a match auto-expands collapsed ancestors and scrolls the row into view
- **Navigation history** — Cmd+[ / Cmd+] step back and forward through every node visited this session; toolbar chevrons show the current position
- **Bookmarks** — Cmd+D toggles a bookmark on any node; toolbar menu lists bookmarks by path string; `bookmark.fill` icon in each bookmarked row; Cmd+D or context menu removes them
- **Tree view** — expandable outline; drag-and-drop to reorder array items; context-menu add/delete
- **Table view** — sticky-header spreadsheet grid for CSV files and uniform JSON/YAML arrays of objects
- **Raw text view** — syntax-highlighted (JSON, XML, YAML, CSV) with font-size control; pretty/minify toggle; text selection enabled
- **CSV column statistics** — "Column Stats" toolbar button opens a per-column breakdown: row count, non-empty, unique count, detected type (Integer/Decimal/String/Mixed), numeric min/max
- **Status bar** — live node count, file size, format label, and full path to the selected node (`root.items[42].name`)
- **Instant open** — simdjson SIMD parsing on a background thread; top-level nodes appear while the rest indexes
- **Zero-copy I/O** — memory-mapped files via `mmap`; a 100 MB file uses < 5 MB of resident memory
- **Lazy value parsing** — only nodes you expand are fully parsed; `AsyncStream` feeds the UI in batches

### Editing
- **Inline value editing** — click any scalar to edit; type auto-detected (null › bool › int › float › string)
- **Key renaming** — double-click a key label
- **Add / delete nodes** — context-menu "Add Key-Value", "Add Item", "Delete"
- **Array reordering** — drag-and-drop rows within the tree view (array children only); Move Up / Move Down also available via context menu
- **Copy / paste** — "Copy as JSON" for any subtree; "Paste from Clipboard" into containers
- **Unlimited undo/redo** — Cmd+Z / Cmd+Shift+Z via native `UndoManager`
- **Save** — Cmd+S round-trips correctly; window dirty dot appears on first edit

### Formats
- **JSON** — simdjson two-phase parse (structural index + lazy value decode)
- **XML** — libxml2 SAX parser; namespace badges, attribute display
- **YAML** — Yams/libyaml AST walk; anchor, scalar-style, and tag badges
- **CSV** — auto-delimiter detection (`,` `;` `\t` `|`); auto-header detection; RFC 4180 quoting
- **Auto-detection** — format sniffed from file content (first 512 bytes), not just extension
- **Export / convert** — "Export as JSON / YAML / CSV…" toolbar menu with native save panel; format conversion in one click

### macOS Integration
- **Welcome window** — drop zone, paste raw text directly into an inline editor, recent files list; no bare Open dialog on launch; Cmd+Shift+0 reopens it
- **Quick Look** — Space bar in Finder previews JSON, XML, YAML, and CSV files (rendered by the embedded `.appex` extension)
- **Spotlight** — all keys and string values are full-text indexed so `mdfind` and Spotlight search find content inside your documents
- **macOS Services** — "Format with MachStruct" and "Minify with MachStruct" appear in the Services menu when text is selected in any app
- **Clipboard watch** — the welcome window detects structured data on the clipboard and offers a one-click "Open" banner
- **Sparkle auto-updates** — background update check on launch; "Check for Updates…" in the app menu

### Settings & Onboarding
- **Preferences (⌘,)** — tree view and raw view font size (11–16 pt); default raw view mode (pretty/minify); show welcome window at launch toggle
- **Onboarding** — feature overview shown once on first launch; re-openable via Help › Show Welcome Guide…

---

## Requirements

| Dependency | Version | Notes |
|---|---|---|
| macOS | 14.0+ | |
| Xcode | 15+ | |
| simdjson | 3.12.3 | Vendored — no install required |
| Yams | 5.4+ | Resolved automatically via SPM |
| Sparkle | 2.x | Resolved automatically via SPM |

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
├── MachStruct.xcodeproj            macOS app target (Info.plist, signing, assets)
├── Sources/
│   └── CSimdjsonBridge/            C++ DOM walker → flat MSIndexEntry[]
│       ├── include/MachStructBridge.h
│       ├── MachStructBridge.cpp
│       └── vendor/                 simdjson 3.12.3 single-header amalgamation
├── MachStruct/
│   ├── Assets.xcassets/            App icon (all macOS sizes, dark navy + node-tree motif)
│   ├── Core/                       MachStructCore library (no UI deps)
│   │   ├── Model/
│   │   │   ├── DocumentNode.swift      NodeID · NodeType · NodeValue · DocumentNode
│   │   │   ├── NodeIndex.swift         O(1) flat lookup (ContiguousArray + positions) + COW + isTabular()
│   │   │   ├── StringTable.swift       Thread-safe string intern pool for key deduplication
│   │   │   ├── ScalarValue.swift       Typed leaf values + parseScalarValue()
│   │   │   ├── EditTransaction.swift   Reversible edit ops + factory methods
│   │   │   ├── FormatMetadata.swift    Per-format annotations (XML/YAML/CSV metadata)
│   │   │   └── SearchEngine.swift      Full-text scan; StructuralIndex-direct + NodeIndex paths
│   │   ├── FileIO/
│   │   │   └── MappedFile.swift        mmap wrapper with madvise hints
│   │   ├── Parsers/
│   │   │   ├── StructParser.swift      Protocol · IndexEntry · StructuralIndex
│   │   │   ├── JSONParser.swift        Two-phase parser (simdjson + Foundation)
│   │   │   ├── XMLParser.swift         libxml2 SAX parser
│   │   │   ├── YAMLParser.swift        Yams/libyaml AST walker
│   │   │   ├── CSVParser.swift         RFC 4180 + auto-delimiter/header detection
│   │   │   └── FormatDetector.swift    512-byte content sniffer (JSON/XML/YAML/CSV)
│   │   └── Serializers/
│   │       ├── JSONDocumentSerializer.swift  NodeIndex → JSON Data
│   │       ├── YAMLDocumentSerializer.swift  NodeIndex → YAML text (block style)
│   │       ├── CSVDocumentSerializer.swift   NodeIndex → RFC 4180 CSV (tabular only)
│   │       └── FormatConverter.swift         Unified convert(index:to:) entry point
│   └── App/                        MachStruct executable
│       ├── MachStructApp.swift       AppDelegate · DocumentController · Sparkle · Services
│       ├── WelcomeView.swift         Drop zone · paste editor · recent files · clipboard banner
│       ├── ContentView.swift         Tree/table/raw switcher · toolbar · history · bookmarks
│       ├── ClipboardWatcher.swift    NSPasteboard polling · DetectedClipboard · ClipboardBanner
│       ├── MachStruct.entitlements   App Sandbox + user-selected read-write
│       ├── Info.plist                UTType declarations · NSServices · Sparkle keys
│       ├── Document/
│       │   └── StructDocument.swift    ReferenceFileDocument; async load; format dispatch
│       └── UI/
│           ├── Bookmarks/
│           │   └── BookmarkEnvironment.swift  bookmarkedNodeIDs + toggleBookmark env keys
│           ├── CSV/
│           │   └── CSVStatsPanel.swift         Per-column stats sheet (count/unique/type/min/max)
│           ├── Editing/
│           │   └── CommitEditEnvironment.swift  commitEdit / serializeNode env keys
│           ├── Onboarding/
│           │   └── OnboardingView.swift         First-launch 6-card feature grid
│           ├── RawView/
│           │   └── SyntaxHighlighter.swift      NSMutableAttributedString regex highlighter
│           ├── Search/
│           │   └── SearchEnvironment.swift      searchMatchIDs + activeSearchMatchID env keys
│           ├── Settings/
│           │   └── SettingsView.swift           Tabbed ⌘, Preferences (AppSettings.Keys)
│           ├── TableView/
│           │   └── TableView.swift              Sticky header + LazyVStack grid for tabular data
│           ├── Toolbar/
│           │   └── StatusBar.swift              Node count · file size · format · node path
│           └── TreeView/
│               ├── ExpandedTreeView.swift       Flat [FlatRow] tree · drag-and-drop · scroll
│               ├── NodeRow.swift                Editing · bookmarks · copy/paste · badges
│               ├── TreeNode.swift               Recursive data wrapper; badge helpers
│               ├── TreeView.swift               SwiftUI List + OutlineGroup (legacy entry)
│               └── TypeBadge.swift              Colored capsule pills (str/int/bool/obj/arr…)
├── MachStructQuickLook/            Quick Look Preview Extension (.appex)
│   ├── PreviewViewController.swift   QLPreviewingController; UTF-8 NSTextView; 256 KB limit
│   └── Info.plist
├── MachStructSpotlight/            Spotlight Importer (.mdimporter)
│   ├── GetMetadata.swift             @_cdecl("GetMetadataForFile"); kMDItemTextContent ≤ 1 MB
│   ├── schema.strings
│   └── Info.plist
├── MachStructTests/                332 tests
│   ├── …Parser/Serializer/Model tests
│   └── Performance/
│       └── ParseBenchmarks.swift     Hard timing assertions with os_signpost
├── .github/
│   └── workflows/
│       └── release.yml               CI: archive → notarize → staple → DMG → GitHub Release draft
└── scripts/
    ├── appcast.xml                   Sparkle RSS feed template
    ├── README-signing.md             Certificate setup, archiving, notarization guide
    └── README-sparkle.md             generate_keys, sign_update, per-release appcast workflow
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
    │   Result: StructuralIndex (compact, ~100 B/node)
    │
    ▼
Shallow NodeIndex — only root + visible children materialised
    │   Files < 5 MB: eager full build
    │   Files ≥ 5 MB: buildShallowNodeIndex() — O(visible)
    │
    ▼
UI renders top-level tree (or table) immediately
    │
    ▼
Phase 2 — On-demand materialisation + value parsing
        When a node is expanded, its children are built from the
        StructuralIndex and their values parsed from the mmap'd region.
        LRU eviction removes cold nodes above 50K to keep memory bounded.
        For a 500K-node file, the user typically touches fewer than 500.
```

### Performance (M1 Mac mini, release build)

| File | Size | Nodes | Index time | NodeIndex build |
|---|---|---|---|---|
| large.json | 10 MB | 210 K | **~112 ms** ✅ (target < 200 ms) | ~41 ms (shallow) |
| huge.json | 100 MB | 710 K | **~264 ms** ✅ (target < 1 500 ms) | O(visible) |
| pathological_wide | 10 MB | 350 K | ~180 ms | — |
| pathological_deep | — | depth 401 | ~17 ms | — |

Memory for 100 MB files stays under 150 MB resident thanks to lazy materialisation + LRU eviction (50 K node threshold).

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

### Phase 4 — Power Tools ✅ v1.0 complete
- [x] P4-01 Full-text search — Cmd+F, keys + values, yellow/amber highlights, ↑↓ navigation
- [x] P4-02 Auto-expand on search nav — navigating to a match auto-expands ancestors, scrolls into view
- [x] P4-03 Bookmarks — Cmd+D toggle; toolbar menu with path-string labels; `bookmark.fill` in NodeRow
- [x] P4-04 Format/minify — segmented picker in raw view toolbar; async re-serialization
- [x] P4-05 Drag-and-drop reordering — `ForEach.onMove` in `ExpandedTreeView`; array children only
- [x] Syntax highlighting — JSON/XML/YAML/CSV regex colouring via `SyntaxHighlighter`; 150 KB limit
- [x] CSV column statistics — per-column sheet: count, unique, type, min/max
- [x] Navigation history — Cmd+[ / Cmd+] back/forward; toolbar chevrons; deduplication
- [x] Clipboard watch — 1.5 s poll; format sniff; animated banner with one-click Open

### Phase 5 — Release Engineering ✅ v1.0 complete
- [x] P5-01 Vendor simdjson (bundled amalgamation v3.12.3 — no Homebrew required)
- [x] P5-02 Xcode app target + `Info.plist` UTType declarations + `GENERATE_INFOPLIST_FILE = NO`
- [x] P5-03 App icon (`AppIcon.appiconset` — dark navy + node-tree motif, all macOS sizes)
- [x] P5-04 Code signing (entitlements, `ExportOptions-Direct.plist`, `ExportOptions-AppStore.plist`, Hardened Runtime)
- [x] P5-05 Notarization + GitHub Actions release pipeline → notarized DMG draft on tag push
- [x] P5-06 Sparkle 2 auto-updates — `SPUStandardUpdaterController`; appcast template; EdDSA key placeholder
- [ ] P5-07 App Store submission prep — screenshots, listing copy, `xcrun altool` validation *(v1.1)*

### ADR-001 — Performance Architecture ✅
- [x] Lazy NodeIndex — `buildShallowNodeIndex()` + `materializeChildrenIfNeeded` (O(visible) memory)
- [x] `SearchEngine` operates on `StructuralIndex.entries` directly (no full materialisation for search)
- [x] Progressive loading UI — animated node count via `parseProgressively` AsyncStream
- [x] `StringTable` string interning for `DocumentNode.key` (thread-safe deduplication)
- [x] `ContiguousArray<DocumentNode>` flat storage in `NodeIndex` (~56 B/node saving)
- [x] `entryIDBase` arithmetic lookup replaces `[NodeID: Int]` dict in `StructuralIndex`
- [x] LRU eviction — cold nodes evicted above 50 K threshold; re-materialised on demand

### Phase 6 — Polish ✅ v1.0 complete
- [x] P6-01 Settings UI — tabbed ⌘, Preferences: font sizes, default raw mode, welcome-on-launch toggle
- [x] P6-02 Welcome / launch window — drop zone, Open File button, recent files list, Cmd+Shift+0
- [x] P6-03 Paste raw text on welcome screen — inline TextEditor, auto-detect format, opens as untitled doc
- [x] P6-04 Onboarding — first-launch 6-card feature grid; Help › Show Welcome Guide… re-opens it
- [x] P6-05 Quick Look plugin — `.appex` embedded; UTF-8 preview; 256 KB limit; JSON/XML/YAML/CSV
- [x] P6-06 Spotlight importer — `.mdimporter` embedded; `kMDItemTextContent` ≤ 1 MB full-text index
- [x] macOS Services — "Format with MachStruct" / "Minify with MachStruct" in system Services menu
- [ ] Accessibility audit — VoiceOver, keyboard-only navigation, Dynamic Type *(v1.1)*
- [ ] Performance audit — profile against PERFORMANCE.md targets on current hardware *(v1.1)*
- [ ] Localisation — en, de, fr, ja *(v1.1)*

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
| [`scripts/README-sparkle.md`](scripts/README-sparkle.md) | generate_keys, sign_update, per-release appcast workflow |
| [`.github/workflows/release.yml`](.github/workflows/release.yml) | CI release pipeline: notarize → DMG → GitHub Release draft |

---

## License

MIT © 2026 Lustech
