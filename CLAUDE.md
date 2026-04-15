# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build the core library and CLI (no UI)
swift build -c release

# Run all tests
swift test

# Run a single test class
swift test --filter JSONParserTests

# Run a single test method
swift test --filter JSONParserTests/testLargeFile

# Open the full macOS app in Xcode (required for UI, signing, UTTypes)
open MachStruct.xcodeproj
```

The first `swift test` run generates ~120 MB of corpus files in `NSTemporaryDirectory()` and caches them. Subsequent runs are fast.

`swift build`/`swift test` only cover `MachStructCore` and CLI targets. The app target (SwiftUI, document lifecycle, extensions) requires Xcode.

## Architecture

### Module Structure

**`Sources/CSimdjsonBridge`** — C++17 bridge exposing `ms_build_structural_index()` which wraps simdjson v3.12.3 (vendored single-header amalgamation, no Homebrew required). Produces a flat `MSIndexEntry[]` array of byte offsets, node types, depths, and parent IDs.

**`MachStruct/Core/`** (`MachStructCore` SPM target) — No UI dependencies.
- `Model/` — `DocumentNode`, `NodeIndex` (O(1) flat lookup via `ContiguousArray` + positions dict, COW), `StringTable` (thread-safe key interning), `ScalarValue`, `EditTransaction`, `SearchEngine`, `FormatMetadata`
- `FileIO/` — `MappedFile` (mmap + madvise, zero-copy)
- `Parsers/` — `StructParser` protocol, `JSONParser` (simdjson + Foundation fallback), `XMLParser` (libxml2 SAX), `YAMLParser` (Yams), `CSVParser` (RFC 4180 actor), `FormatDetector`
- `Serializers/` — `JSONDocumentSerializer`, `YAMLDocumentSerializer`, `CSVDocumentSerializer`, `FormatConverter`

**`MachStruct/App/`** (`MachStruct` executable target) — SwiftUI app lifecycle.
- `MachStructApp.swift` — AppDelegate, `MachStructDocumentController`, Sparkle, Services handlers
- `Document/StructDocument.swift` — `ReferenceFileDocument`; async load; format dispatch
- `ContentView.swift` — tree/table/raw view switcher, toolbar, navigation history, bookmarks
- `UI/TreeView/ExpandedTreeView.swift` — flat `[FlatRow]` tree, drag-and-drop, scroll; the primary view for large files

**`MachStructQuickLook/`** and **`MachStructSpotlight/`** — embedded `.appex`/`.mdimporter` extensions, managed via `MachStruct.xcodeproj`.

**`MachStructTests/`** — 332 tests; `Performance/ParseBenchmarks.swift` has hard timing assertions with `os_signpost`.

### Two-Phase Parsing

1. **Phase 1 (Structural Index):** Parser scans the entire file and produces a flat `[IndexEntry]` (byte offsets, types, depths, parent IDs). No string/number values are decoded. Result: `StructuralIndex` (~100 B/node). `madvise(MADV_SEQUENTIAL)` is set during this phase.
2. **Shallow NodeIndex build:** Files >= 5 MB use `buildShallowNodeIndex()` — materialises only root + visible children. Files < 5 MB use eager `buildNodeIndex()` (full tree). `NodeIndex` uses `ContiguousArray<DocumentNode>` + `[NodeID: Int]` positions for O(1) lookup with ~224 B/node.
3. **Phase 2 (Lazy materialisation + value parsing):** When a node is expanded, `StructDocument.materializeChildrenIfNeeded` builds `DocumentNode`s from `StructuralIndex` entries and parses values from mmap'd bytes. `madvise(MADV_RANDOM)` is set. LRU eviction removes cold nodes above 50 K to keep memory bounded. Most nodes in large files are never touched.

`JSONParser` uses simdjson for Phase 1 and Foundation `JSONSerialization` for Phase 2 value slices. Files < 5 MB use Foundation-only (single-pass, skips the C bridge). `NodeValue.unparsed` is the default state for all nodes until Phase 2 runs.

`FormatDetector` sniffs the first 512 bytes to choose the parser; extension is the fallback.

`SearchEngine` has two paths: `search(query:in:file:)` iterates `StructuralIndex.entries` directly (lazy files, avoids full materialisation); `search(query:in:)` traverses `NodeIndex` (small files).

### Key Architectural Constraints

- **Never block the main actor.** Parsing and indexing run on background actors (`Task.detached` or dedicated actors). SwiftUI views observe `@Published` properties on the main actor.
- **COW structs everywhere** for `NodeIndex` and `DocumentNode` — use `var` copies, not `inout` references.
- **`Sendable` on everything** that crosses concurrency boundaries.
- **Actors** for parser/registry state; `nonisolated` for stateless helpers.
- Performance targets (M1 MacBook Air, release build): 10 MB file → first nodes visible < 100 ms, full index < 200 ms; 100 MB file → first nodes visible < 500 ms, full index < 1.5 s; tree node expand (100 children) < 16 ms; memory while browsing < 150 MB resident for 100 MB files.
- Saving after a single-value edit: only the modified byte range is rewritten; unmodified regions are memcpy'd from the mmap'd source. Full re-serialization via `JSONSerialization` is used in Phase 2 (adequate for < 100 MB files); splice-based save is a future optimisation.

### Performance Architecture (ADR-001 — complete)

All phases of ADR-001 are implemented. Key internals:
- **`StructuralIndex`** — flat `[IndexEntry]` (100–120 B/node) + `childIndices: [NodeID: [Int]]` + `entryIDBase: UInt64` for O(1) arithmetic lookup (no hash table). `keyTable: StringTable` interns keys lazily.
- **`NodeIndex`** — `ContiguousArray<DocumentNode>` + `[NodeID: Int]` positions (~224 B/node vs ~280 B with old dict). `evictNodes(_:)` supports LRU removal without touching parent `childIDs`.
- **`StringTable`** — `NSLock`-protected `[String: String]` intern pool. All `DocumentNode.key` values go through it so repeated keys share backing storage.
- **`StructDocument`** — `materializeChildrenIfNeeded(of:expandedIDs:selectedID:)` builds nodes on expand. `evictIfNeeded` fires after each materialisation when count > 50 K. Hot set: root + root children + expanded + their children + selected.
- **`SearchEngine`** — `search(query:in:file:)` iterates `StructuralIndex.entries` directly for lazy files. No full materialisation needed for first search.
- **`entryIDBase`** — NodeIDs are globally monotonic, so `entries[id.rawValue - entryIDBase]` gives O(1) lookup without building any index dict.

See `docs/ADR-001-performance-architecture.md` for the full decision record and measured results.

### Test Corpus

`MachStructTests/Generators/TestCorpusGenerator.swift` generates corpus files on first run and caches them in `NSTemporaryDirectory()`. Files: `tiny.json` (1 KB), `medium.json` (1 MB), `large.json` (10 MB), `huge.json` (100 MB), `pathological_deep.json`, `pathological_wide.json`. `ParseBenchmarks.swift` uses `os_signpost` — profile in Instruments using the Time Profile template.

Debug builds use a relaxed 6 000 ms parse threshold; release SLA is 1 500 ms.

### Xcodeproj Gotchas (from Phase 5 implementation)

- **`NSApp` is nil at `App.init()` time** — never call `NSApp.setActivationPolicy()` from the SwiftUI `App` struct initialiser.
- **`LSItemContentTypes` is mandatory** — `CFBundleTypeExtensions` alone is insufficient on macOS 14+. Each `CFBundleDocumentTypes` entry must include an `LSItemContentTypes` array.
- **`public.yaml` must be in `UTImportedTypeDeclarations`** — not guaranteed system-wide on macOS 14; `UTType(filenameExtension: "yaml")` won't resolve without it.
- **`GENERATE_INFOPLIST_FILE = NO`** — the xcodeproj explicitly sets this; don't let Xcode auto-generate the Info.plist.

## Conventions

- Add new formats by implementing the `StructParser` protocol (`buildIndex(from:)`, `parseValue(entry:from:)`, `serialize(value:)`, `validate(file:)`) in `MachStruct/Core/Parsers/`.
- `EditTransaction` snapshots capture only affected nodes (`beforeSnapshot`/`afterSnapshot` as `[NodeID: DocumentNode]`). `undo`/`redo` apply the inverse snapshot. Transactions are registered with `NSDocument`'s `UndoManager` — do not use the undo manager directly from views.
- Environment keys for cross-view state: `CommitEditEnvironment`, `SearchEnvironment`, `BookmarkEnvironment` (passed via SwiftUI environment, not direct bindings).
- `AppSettings.Keys` constants are the single source of truth for `UserDefaults` keys.
- Sparkle auto-update dialogs are suppressed in DEBUG builds (`#if DEBUG`).
- The welcome window is implemented via `NSWindow` + `NSHostingController`, not SwiftUI `Window` scene — this avoids macOS 14 `DocumentGroup` ordering issues. Re-shown on Dock click via `applicationShouldHandleReopen`.
- `v1.0` is feature-complete (Phases 1–6 + ADR-001 performance work). Remaining roadmap items: App Store submission (P5-07), NSTextView raw view wrapper (ADR-001 Phase 3.1), accessibility/localisation (v1.1). See `docs/roadmap/ROADMAP.md` and `docs/tasks/TASK-INDEX.md` for task IDs used in commit messages.
