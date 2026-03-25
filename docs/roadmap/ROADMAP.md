# MachStruct Roadmap

> Phased delivery plan from MVP to full structured-document toolkit.

## Phase Overview

| Phase | Codename | Focus | Timeline Estimate |
|---|---|---|---|
| **Phase 1** | Foundation | JSON viewer with core tree UI | ✅ Complete |
| **Phase 2** | Editor | JSON editing, undo, save | ✅ Complete |
| **Phase 3** | Formats | XML, YAML, CSV support | 4–6 weeks |
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

## Phase 3: Format Expansion

**Goal:** Support XML, YAML, and CSV with the same UX quality as JSON.

### Deliverables — XML
1. **XMLParser** — Using libxml2 SAX API (ships with macOS). Maps elements, attributes, and text to DocumentNode.
2. **XML-specific UI** — Namespace badges, attribute display, self-closing tag indicators.
3. **XML syntax highlighting** in raw text view.

### Deliverables — YAML
4. **YAMLParser** — Using libyaml (SPM package). Handles anchors, aliases, tags, and multi-line strings.
5. **YAML-specific UI** — Anchor/alias indicators, scalar style badges (literal, folded).
6. **YAML syntax highlighting** in raw text view.

### Deliverables — CSV
7. **CSVParser** — Custom line scanner with auto-delimiter detection (comma, tab, semicolon, pipe).
8. **Table view** — Automatic table rendering for CSV files (and JSON arrays of uniform objects).
9. **Column stats** — Quick statistics per column (type distribution, unique count, min/max for numbers).

### Deliverables — Cross-format
10. **Format conversion** — Convert between any two supported formats (JSON ↔ XML, YAML → JSON, CSV → JSON, etc.).
11. **Auto-detection** — Detect format from file content, not just extension.

### Exit Criteria
- All four formats parse, display, edit, and save correctly.
- Format conversion round-trips without data loss (where format differences allow).
- Performance targets met for all formats at their respective file sizes.

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
