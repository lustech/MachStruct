# Task Index

> AI-friendly implementation task breakdown. Each task is self-contained with clear inputs, outputs, and acceptance criteria — designed to be handed to an AI coding agent one at a time.

## How to Use This File

Each task follows this structure:
- **ID** — Stable reference (e.g., `P1-01`). Use in commit messages and PR titles.
- **Phase** — Which roadmap phase this belongs to.
- **Module** — Which code module is affected.
- **Dependencies** — Tasks that must be completed first.
- **Description** — What to build.
- **Key files** — Expected file paths in the project.
- **Acceptance criteria** — How to know it's done.
- **Reference docs** — Which architecture docs to read first.

When starting a task, the AI agent should: (1) read the reference docs, (2) check that dependencies are complete, (3) implement, (4) verify acceptance criteria, (5) run tests.

---

## Phase 1: Foundation

### P1-01: Project Scaffold
- **Module:** Root
- **Dependencies:** None
- **Description:** Create the Xcode project with SwiftUI App lifecycle, SPM Package.swift, and the folder structure from ARCHITECTURE.md. Configure for macOS 14+ deployment target. Set up the module structure: MachStructCore, MachStructDocument, MachStructUI.
- **Key files:** `Package.swift`, `MachStruct/App/MachStructApp.swift`, `MachStruct/App/ContentView.swift`
- **Acceptance criteria:** Project builds and launches with an empty window. All module folders exist.
- **Reference docs:** ARCHITECTURE.md §7

### P1-02: MappedFile
- **Module:** Core/FileIO
- **Dependencies:** P1-01
- **Description:** Implement the `MappedFile` class that wraps mmap/munmap with safe Swift lifecycle. Support madvise hints (sequential and random). Provide a `slice(offset:length:)` method for zero-copy access. Handle errors (file not found, permission denied, mmap failure).
- **Key files:** `MachStruct/Core/FileIO/MappedFile.swift`
- **Acceptance criteria:** Unit tests: open a 10MB test file, read slices at various offsets, verify contents match. Memory test: mmap a 100MB file and confirm resident memory stays under 10MB when only reading the first page.
- **Reference docs:** PARSING-ENGINE.md §3

### P1-03: simdjson C Bridge
- **Module:** Core/Parsers
- **Dependencies:** P1-01
- **Description:** Add simdjson as a C/C++ dependency via SPM. Create a minimal C bridge header (`MachStructBridge.h`) exposing the `ms_build_structural_index` function per PARSING-ENGINE.md §4. Create an SPM C target wrapping the bridge.
- **Key files:** `MachStruct/Core/Parsers/Bridge/MachStructBridge.h`, `MachStruct/Core/Parsers/Bridge/MachStructBridge.c`, `Sources/CSimdjsonBridge/...`
- **Acceptance criteria:** Swift can call `ms_build_structural_index` on a test JSON file and get back a valid array of `MSIndexEntry` structs. No memory leaks under Instruments.
- **Reference docs:** PARSING-ENGINE.md §4

### P1-04: Core Data Model
- **Module:** Core/Model
- **Dependencies:** P1-01
- **Description:** Implement `NodeID`, `NodeType`, `ScalarValue`, `DocumentNode`, `NodeValue`, `SourceRange`, `FormatMetadata`, and the `NodeIndex` struct with full query API (lookup by ID, children, parent, path, search). Ensure COW semantics and Sendable conformance.
- **Key files:** `MachStruct/Core/Model/DocumentNode.swift`, `MachStruct/Core/Model/NodeIndex.swift`, `MachStruct/Core/Model/ScalarValue.swift`
- **Acceptance criteria:** Unit tests: build a small node tree manually, verify all NodeIndex queries. Test COW: mutate a copy and verify original is unchanged. Test Sendable: use nodes across actor boundaries.
- **Reference docs:** DATA-MODEL.md §2–3

### P1-05: StructParser Protocol
- **Module:** Core/Parsers
- **Dependencies:** P1-04
- **Description:** Define the `StructParser` protocol and `StructuralIndex` type per PARSING-ENGINE.md §5. Include a `ParserRegistry` that maps file extensions to parser instances.
- **Key files:** `MachStruct/Core/Parsers/StructParser.swift`, `MachStruct/Core/Parsers/ParserRegistry.swift`
- **Acceptance criteria:** Protocol compiles. Registry can register and look up parsers by extension.
- **Reference docs:** PARSING-ENGINE.md §5

### P1-06: JSONParser Implementation
- **Module:** Core/Parsers
- **Dependencies:** P1-02, P1-03, P1-04, P1-05
- **Description:** Implement `JSONParser` conforming to `StructParser`. Phase 1 (structural indexing) uses the simdjson bridge. Phase 2 (value parsing) uses Foundation's JSONSerialization on byte slices. Support progressive parsing via AsyncStream. Fall back to Foundation-only path for files < 5MB.
- **Key files:** `MachStruct/Core/Parsers/JSONParser.swift`
- **Acceptance criteria:** Benchmark: 10MB file indexed in < 200ms. 100MB file indexed in < 1.5s. All test corpus files parse correctly (including malformed.json with graceful errors). Progressive stream emits at least 10 batches for a 100MB file.
- **Reference docs:** PARSING-ENGINE.md §2, §4, §6

### P1-07: StructDocument (NSDocument)
- **Module:** Document
- **Dependencies:** P1-04, P1-06
- **Description:** Implement `StructDocument` as an NSDocument subclass that opens files using MappedFile, parses with the appropriate StructParser, and holds the NodeIndex. Register for JSON file type UTIs. Support recent files and multi-window.
- **Key files:** `MachStruct/App/StructDocument.swift`, `Info.plist` UTI declarations
- **Acceptance criteria:** Can open .json files via File > Open, drag-and-drop, and double-click from Finder. Recent files menu works. Multiple files open in separate windows.
- **Reference docs:** ARCHITECTURE.md §4.2

### P1-08: TreeView Component
- **Module:** UI/TreeView
- **Dependencies:** P1-04, P1-07
- **Description:** Implement the primary tree view using SwiftUI List + OutlineGroup. Each row shows expand arrow, key, value (truncated), and type badge. Lazy child loading on expand. Keyboard navigation (arrow keys, Enter, Space).
- **Key files:** `MachStruct/UI/TreeView/TreeView.swift`, `MachStruct/UI/TreeView/NodeRow.swift`, `MachStruct/UI/TreeView/TypeBadge.swift`
- **Acceptance criteria:** 100MB file renders top-level nodes without lag. Expanding a node with 10K children scrolls smoothly at 60fps. Type badges display correct colors per UI-DESIGN.md.
- **Reference docs:** UI-DESIGN.md §3.1, PERFORMANCE.md §1

### P1-09: Status Bar
- **Module:** UI/Toolbar
- **Dependencies:** P1-08
- **Description:** Bottom status bar showing: node count, file size, format name, and path to the currently selected node (e.g., `root.items[42].name`).
- **Key files:** `MachStruct/UI/Toolbar/StatusBar.swift`
- **Acceptance criteria:** All four data points update correctly as the user navigates the tree.
- **Reference docs:** UI-DESIGN.md §2

### P1-10: Benchmark Test Suite
- **Module:** Tests
- **Dependencies:** P1-06, P1-08
- **Description:** Create a test corpus generator that produces JSON files at 1KB, 1MB, 10MB, 100MB with varying characteristics (deep nesting, wide arrays, mixed types, malformed). Write XCTest performance tests measuring parse time, index memory, and tree render time. Integrate with os_signpost for Instruments.
- **Key files:** `MachStructTests/Generators/TestCorpusGenerator.swift`, `MachStructTests/Performance/ParseBenchmarks.swift`, `MachStructTests/Performance/UIBenchmarks.swift`
- **Acceptance criteria:** All performance targets from PERFORMANCE.md §1 pass on M1 MacBook Air.
- **Reference docs:** PERFORMANCE.md §2

---

## Phase 2: Editor ✅ COMPLETE

| ID | Task | Status | Key Deliverable |
|---|---|---|---|
| P2-01 | Inline value editing   | ✅ | `NodeRow` TextField; `parseScalarValue` auto-type; Return/Escape |
| P2-02 | Key renaming           | ✅ | Double-click key label; `EditTransaction.renameKey` |
| P2-03 | Add/delete nodes       | ✅ | Context menu Add Key-Value / Add Item / Delete |
| P2-04 | Array reordering       | ✅ | Move Up/Down context menu; `EditTransaction.moveArrayItem` |
| P2-05 | EditTransaction + Undo | ✅ | `EditTransaction` snapshot model; recursive `tx.reversed` undo/redo |
| P2-06 | Incremental save       | ✅ | `JSONDocumentSerializer`; `StructDocument.snapshot()/fileWrapper()` |
| P2-07 | Dirty state UI         | ✅ | Automatic via `ReferenceFileDocument`; window dot + save dialog |
| P2-08 | Copy/paste nodes       | ✅ | "Copy as JSON" + "Paste from Clipboard"; `insertFromClipboard` factory |
| P2-09 | Raw text view          | ✅ | Toolbar toggle; async `serializeDocument`; monospaced `Text` pane |

### Implementation notes
- **P2-04**: Implemented as Move Up/Down context-menu actions rather than drag-and-drop (deferred to Phase 4 for better native `List` reorder support).
- **P2-06**: Full re-serialization via `JSONDocumentSerializer` + `JSONSerialization` rather than splice-based patching.  Adequate for files up to ~100 MB; `.unparsed` scalar nodes are re-read from the still-alive `MappedFile`.
- **P2-09**: Read-only monospaced text view (no syntax highlighting); highlighting deferred to Phase 4.

### New files (Phase 2)
| File | Module | Purpose |
|---|---|---|
| `Core/Model/EditTransaction.swift` | MachStructCore | Reversible edit operation + 7 factory methods |
| `Core/Model/ScalarValue.swift` | MachStructCore | Added `parseScalarValue()` free function |
| `Core/Serializers/JSONDocumentSerializer.swift` | MachStructCore | NodeIndex → JSON Data |
| `App/Document/StructDocument.swift` | MachStruct | Save support; MappedFile kept alive |
| `App/UI/Editing/CommitEditEnvironment.swift` | MachStruct | `commitEdit` + `serializeNode` environment keys |
| `App/UI/TreeView/NodeRow.swift` | MachStruct | Full editing/move/copy-paste UI |
| `App/ContentView.swift` | MachStruct | Raw view toggle + environment injection |
| `MachStructTests/EditTransactionTests.swift` | Tests | 18 tests for all transaction types |
| `MachStructTests/JSONSerializerTests.swift` | Tests | 21 tests for serializer + move + paste |

---

## Phase 3: Format Expansion (Summary)

| ID | Task | Dependencies | Key Deliverable |
|---|---|---|---|
| P3-01 | XMLParser | P1-05 | libxml2 SAX-based parser |
| P3-02 | XML UI adaptations | P3-01, P1-08 | Namespace badges, attributes |
| P3-03 | YAMLParser | P1-05 | libyaml-based parser |
| P3-04 | YAML UI adaptations | P3-03, P1-08 | Anchor/alias display |
| P3-05 | CSVParser | P1-05 | Auto-delimiter detection |
| P3-06 | Table view | P3-05, P1-08 | Tabular display for arrays/CSV |
| P3-07 | Format conversion | P3-01–P3-05 | Cross-format export |
| P3-08 | Auto-detection | P1-05 | Content-based format sniffing |

---

## Task Dependency Graph (Phase 1)

```
P1-01 (Scaffold)
  ├──▶ P1-02 (MappedFile)
  ├──▶ P1-03 (simdjson Bridge)
  ├──▶ P1-04 (Data Model)
  │      └──▶ P1-05 (StructParser Protocol)
  │
  └──[P1-02 + P1-03 + P1-04 + P1-05]──▶ P1-06 (JSONParser)
                                              │
                                   P1-04 ──▶ P1-07 (StructDocument)
                                              │
                                   P1-07 ──▶ P1-08 (TreeView)
                                              │
                                   P1-08 ──▶ P1-09 (StatusBar)
                                              │
                              P1-06 + P1-08 ──▶ P1-10 (Benchmarks)
```

## Notes for AI Agents

When implementing a task:
1. **Read the reference docs first.** They contain Swift code samples and design rationale.
2. **Follow the naming conventions** from DATA-MODEL.md (types) and ARCHITECTURE.md (modules).
3. **Write tests alongside code.** Each task has acceptance criteria that map to specific tests.
4. **Don't over-engineer.** Phase 1 is about getting the core loop working. Optimize in later phases.
5. **Keep modules decoupled.** Core should never import UI. Document bridges between Core and UI.
6. **Use Swift Concurrency.** Actors for parser state, async/await for file operations, @MainActor for UI.
