# MachStruct Roadmap

> Phased delivery plan from MVP to full structured-document toolkit.

## Phase Overview

| Phase | Codename | Focus | Timeline Estimate |
|---|---|---|---|
| **Phase 1** | Foundation | JSON viewer with core tree UI | ✅ Complete |
| **Phase 2** | Editor | JSON editing, undo, save | ✅ Complete |
| **Phase 3** | Formats | XML, YAML, CSV support | ✅ Complete |
| **Phase 4** | Power Tools | Search, diff, conversion, plugins | 4–6 weeks |
| **Phase 5** | Polish | App Store, Quick Look, Spotlight, performance tuning | 3–4 weeks |

---

## Phase 1: Foundation (JSON Viewer)

**Goal:** Open any JSON file up to 100MB and display it in a navigable tree — fast.

### Deliverables
1. **Xcode project scaffold** — SwiftUI app lifecycle, SPM dependencies, folder structure matching ARCHITECTURE.md.
2. **MappedFile** — mmap wrapper with safe lifecycle and madvise support.
3. **simdjson C bridge** — Minimal C wrapper exposing structural indexing.
4. **JSONParser** — Implements `StructParser` protocol. Two-phase: structural index → lazy value parse.
5. **DocumentNode + NodeIndex** — Core data model with COW semantics.
6. **StructDocument** — NSDocument subclass for file open, recent files, multi-window.
7. **TreeView** — SwiftUI List + OutlineGroup with lazy expansion, type badges, value previews.
8. **Status bar** — Node count, file size, format indicator, current path.
9. **Benchmark suite** — Automated parse + render performance tests with test corpus.

### Exit Criteria
- 100MB JSON file opens with tree visible in < 500ms.
- Scrolling the tree maintains 60fps.
- App opens files via double-click, drag-and-drop, and File > Open.

---

## Phase 2: Editor ✅ COMPLETE

**Goal:** Enable simple, reliable editing of JSON documents.

### Deliverables (as shipped)
1. **Inline value editing** — Click a scalar value to enter an in-row TextField.  Auto-detects type (null › bool › int › float › string).  Return commits; Escape cancels.
2. **Key renaming** — Double-click a key label on any keyValue row.
3. **Add/delete nodes** — Context menu: "Add Key-Value" on objects, "Add Item" on arrays, "Delete" on any non-root node.
4. **Array reordering** — "Move Up" / "Move Down" context-menu actions on direct array children (full undo/redo). *(Originally drag-and-drop; implemented as context menu for Phase 2; drag-and-drop deferred to Phase 4.)*
5. **EditTransaction + UndoManager** — `EditTransaction` (reversible snapshot-based ops) + recursive `tx.reversed` pattern for symmetric Cmd+Z / Cmd+Shift+Z.
6. **Save** — `JSONDocumentSerializer` walks `NodeIndex`, re-reading `.unparsed` scalar bytes from `MappedFile` (kept alive in `StructDocument`), and serializes via `JSONSerialization`. *(Full re-serialization rather than splice-based; adequate for Phase 2 since `JSONSerialization` handles < 100 MB comfortably.)*
7. **Dirty state** — SwiftUI window "edited" dot and save-before-close dialog work automatically via `ReferenceFileDocument.snapshot()` / `fileWrapper()`.
8. **Copy/paste** — "Copy as JSON" puts a node's JSON subtree on `NSPasteboard`. "Paste from Clipboard" parses clipboard JSON and inserts into container (dict keys merged into objects; value appended to arrays).  `EditTransaction.insertFromClipboard` handles arbitrary nesting.
9. **Raw text view** — Toolbar toggle (📄) renders the full document as pretty-printed JSON in a read-only monospaced `Text` view. Serialization runs asynchronously on a detached task.

### Exit Criteria — Status
- ✅ All edit operations register in undo stack (Cmd+Z / Cmd+Shift+Z).
- ✅ Save round-trips correctly (verified by test suite).
- ✅ 126 tests, 0 failures, including 39 new tests for Phase 2 features.

---

## Phase 3: Format Expansion ✅ COMPLETE

**Goal:** Support XML, YAML, and CSV with the same UX quality as JSON.

### Deliverables — XML (as shipped)
1. **XMLParser** — libxml2 SAX-based parser (`XMLParser.swift`). Maps elements, attributes, and text nodes to `DocumentNode`. Handles namespaces, CDATA, and nested structures.
2. **XML-specific UI** — Namespace badges (`.ns`), attribute display in tree rows, self-closing tag indicator in `TypeBadge`.

### Deliverables — YAML (as shipped)
3. **YAMLParser** — Yams 5.x SPM wrapper around libyaml (`YAMLParser.swift`). Full AST walk via `Yams.compose()`; handles mappings, sequences, scalars, multi-document files.
4. **YAML-specific UI** — Anchor badge (`&`), scalar style badges: literal (`|`), folded (`>`), single-quoted (`'`), double-quoted (`"`). Rendered inline alongside the type badge in `NodeRow`.

### Deliverables — CSV (as shipped)
5. **CSVParser** — Custom RFC 4180 actor (`CSVParser.swift`). Auto-delimiter detection (comma, tab, semicolon, pipe) by consistency scoring across the first 5 lines. Auto-header detection (first row is header if all cells are non-numeric strings).
6. **Table view** — `TableView` SwiftUI component: sticky column header, `LazyVStack` data rows for virtualization, tap-to-select synced with the tree-view selection binding. Accessible via toolbar toggle whenever `NodeIndex.isTabular()` is true.

### Deliverables — Cross-format (as shipped)
7. **Format conversion** — Export menu in the window toolbar: "Export as JSON / YAML / CSV…" with a native `NSSavePanel`. `FormatConverter` (stateless struct) delegates to `JSONDocumentSerializer`, `YAMLDocumentSerializer`, and `CSVDocumentSerializer`. CSV export is disabled when the document is not tabular.
8. **Auto-detection** — `FormatDetector` probes the first 512 bytes: first-byte dispatch for JSON (`{`/`[`) and XML (`<`), explicit YAML markers (`---`, `%YAML`, `%TAG`), then delimiter-consistency scoring for CSV, then YAML structural heuristics (`key: value`, `- item`), finally file-extension fallback. `StructDocument` now accepts all four format UTTypes and dispatches to the right parser automatically.

### Implementation notes
- **Syntax highlighting** in the raw text view deferred to Phase 4 (all formats currently shown as plain monospaced text).
- **CSV column statistics** (type distribution, unique count, min/max) deferred to Phase 4.
- **YAML anchor capture** is limited by Yams storing anchors as `weak var`; by the time the parsed `Node` tree is walked, anchor objects have been released. Alias *resolution* (same content) works correctly.
- `ParserRegistry.shared` is now populated with all four parsers; `parser(for:file:fileExtension:)` combines content sniffing with the registry for best-effort format selection.

### Exit Criteria — Status
- ✅ All four formats parse and display correctly.
- ✅ Format conversion: JSON ↔ YAML ↔ CSV round-trips verified by test suite.
- ✅ 332 tests, 0 failures (49 `FormatDetectorTests` + 33 `FormatConverterTests` + parser/UI tests).

---

## Phase 4: Power Tools

**Goal:** Features that differentiate MachStruct from basic viewers.

### Deliverables
1. **Full-text search** — Search across keys and values with highlighting.
2. **Path queries** — JQ-style expressions for targeted navigation and filtering.
3. **Diff view** — Compare two documents or two versions of the same document. Highlight added, removed, and changed nodes.
4. **Schema validation** — Validate JSON against JSON Schema, XML against XSD/DTD.
5. **Format/minify** — Pretty-print or minify JSON/XML/YAML.
6. **Bookmarks** — Pin frequently accessed nodes for quick return.
7. **History** — Recently viewed nodes within a document, like browser history.
8. **Clipboard watch** — Detect JSON/XML on the clipboard and offer to open in MachStruct.
9. **Syntax highlighting** in raw text view (JSON, XML, YAML, CSV) — deferred from Phase 3.
10. **CSV column statistics** — Type distribution, unique count, min/max per column — deferred from Phase 3.
11. **Drag-and-drop reordering** in tree view — deferred from Phase 2 (native `List` reorder support).

### Exit Criteria
- Search returns results in < 1s for 100MB files.
- Diff correctly identifies all changes between two 10MB files.

---

## Phase 5: Polish and Distribution

**Goal:** App Store readiness and deep macOS integration.

### Deliverables
1. **Quick Look plugin** — Preview JSON/XML/YAML/CSV files in Finder with a mini tree view.
2. **Spotlight importer** — Index document keys and string values for system-wide search.
3. **macOS Services** — "Format JSON" and "Minify JSON" in any app's Services menu.
4. **App Store preparation** — Sandboxing, notarization, screenshots, description, pricing.
5. **Settings UI** — Theme, font, indent style, default format, keyboard shortcuts.
6. **Onboarding** — First-launch tutorial highlighting key features.
7. **Performance audit** — Profile every target in PERFORMANCE.md. Fix any regressions.
8. **Accessibility audit** — VoiceOver, keyboard-only, high contrast, Dynamic Type.

### Exit Criteria
- App passes App Store review.
- All accessibility features functional.
- All performance targets met per PERFORMANCE.md.

---

## Future Phases (Ideas, Not Committed)

These are explored further in [FEATURE-IDEAS.md](FEATURE-IDEAS.md):

- **Phase 6:** Binary formats (MessagePack, BSON, Protobuf, CBOR)
- **Phase 7:** Collaborative editing / file watching / live reload
- **Phase 8:** Plugin system for custom parsers and transformations
- **Phase 9:** iOS/iPadOS companion app
- **Phase 10:** AI-assisted features (schema inference, data summarization, natural language queries)
