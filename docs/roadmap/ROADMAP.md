# MachStruct Roadmap

> Phased delivery plan from MVP to full structured-document toolkit.

## Phase Overview

| Phase | Codename | Focus | Timeline Estimate |
|---|---|---|---|
| **Phase 1** | Foundation | JSON viewer with core tree UI | ✅ Complete |
| **Phase 2** | Editor | JSON editing, undo, save | ✅ Complete |
| **Phase 3** | Formats | XML, YAML, CSV support | ✅ Complete |
| **Phase 4** | Power Tools | Search, diff, conversion, plugins | 4–6 weeks |
| **Phase 5** | Release Engineering | simdjson vendoring, Xcode target, signing, notarization, Sparkle, App Store | 2–3 weeks |
| **Phase 6** | Polish | Settings, onboarding, Quick Look, Spotlight, accessibility, localisation | 3–4 weeks |

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

## Phase 5: Release Engineering

**Goal:** Get MachStruct into users' hands as a self-contained, signed, auto-updating macOS app — via direct notarized DMG first, App Store second.

### Current blockers (must fix before any release)

Three issues in the current codebase prevent shipping:

1. **`simdjson` is a Homebrew system library** — The `CSystemSimdjson` SPM target points at `/opt/homebrew/`. This breaks on machines without Homebrew and is rejected by the Mac App Store. Must be replaced with vendored source.
2. **No Xcode app target** — `Package.swift` produces a command-line-style executable, not a proper `.app` bundle. Shipping requires a real Xcode target with `Info.plist`, entitlements, and an asset catalog.
3. **No signing or sandboxing configuration** — Neither distribution channel works without these.

### Distribution channels

| Channel | When | Notes |
|---|---|---|
| **Notarized DMG** | v1.0 | Fastest path; no review; Sparkle handles updates |
| **Mac App Store** | v1.1+ | After v1.0 proves stable; broader discovery |

### Deliverables

1. **Vendor simdjson** *(P5-01)* — Replace the `systemLibrary` SPM target with the simdjson single-header amalgamation (`simdjson.h` + `simdjson.cpp`) checked in under `Sources/CSimdjsonBridge/vendor/`. Drop the Homebrew dependency entirely.

2. **Xcode app target + Info.plist** *(P5-02)* — Create a proper `.xcodeproj` app target. `Info.plist` declares all five UTTypes (JSON, XML, YAML, YML, CSV) for `CFBundleDocumentTypes`. Entitlements file grants `com.apple.security.files.user-selected.read-write` (sandbox-compatible with `ReferenceFileDocument`).

3. **App icon** *(P5-03)* — `AppIcon.appiconset` at all required sizes (16 → 1024 pt, @1x + @2x). Icon reflects the structured-document inspector theme.

4. **Code signing configuration** *(P5-04)* — Developer ID Application certificate (direct distribution) and Apple Distribution certificate (App Store). Two `ExportOptions.plist` files, one per channel. `xcodebuild archive` + `xcodebuild -exportArchive` verified.

5. **Notarization pipeline** *(P5-05)* — GitHub Actions workflow triggered on `v*` tag push: archive → export → `xcrun notarytool submit --wait` → `xcrun stapler staple` → `hdiutil create` DMG → upload to GitHub Release. `spctl --assess` passes on a clean machine.

6. **Sparkle auto-updates** *(P5-06)* — Add Sparkle 2 (SPM). `SUFeedURL` in `Info.plist` points at a hosted `appcast.xml`. Appcast signed with EdDSA key. Update check runs in background on launch.

7. **App Store submission prep** *(P5-07)* — Sandbox entitlements audited (only `user-selected.read-write` required for `DocumentGroup`). App Store Connect listing: screenshots at 1280×800 and 1440×900, description, keywords, age rating, pricing. `xcrun altool --validate-app` clean before submission.

### Recommended sequencing

```
P5-01 (vendor simdjson) ──▶ P5-02 (Xcode target) ──▶ P5-04 (signing)
                                   │                          │
                              P5-03 (icon)             P5-05 (notarize CI)
                                                              │
                                                       P5-06 (Sparkle)
                                                              │
                                                       ship v1.0 DMG
                                                              │
                                                       P5-07 (App Store)
```

### What's already in good shape

- `ReferenceFileDocument` / `DocumentGroup` is the correct sandbox-friendly architecture — security-scoped bookmarks are handled automatically.
- `MappedFile` writes to `NSTemporaryDirectory()` before mmapping — permitted in the sandbox.
- `StructDocument.readableContentTypes` already lists all five UTTypes — maps directly to `Info.plist` `CFBundleDocumentTypes`.
- All four parsers are actors and all model types are `Sendable` — no concurrency surprises after signing.

### Exit Criteria
- `swift build` succeeds on a machine without Homebrew installed.
- `spctl --assess --type exec MachStruct.app` exits 0 on a clean macOS install.
- Sparkle update dialog appears when a newer version is published to the appcast.
- App Store validation (`xcrun altool --validate-app`) passes with no errors.

---

## Phase 6: Polish and Deep Integration

**Goal:** Deep macOS integration, accessibility, onboarding, and App Store quality bar.

### Deliverables
1. **Settings UI** — Theme (light/dark/auto), font size, indent width, default format on paste, keyboard shortcut customisation.
2. **Onboarding** — First-launch welcome sheet highlighting key features and pointing to docs.
3. **Quick Look plugin** — Preview JSON/XML/YAML/CSV files in Finder with a read-only mini tree view.
4. **Spotlight importer** — Index document keys and string values for Spotlight (`mdimport`).
5. **macOS Services** — "Format JSON" and "Minify JSON" in the system Services menu.
6. **Performance audit** — Profile every target from PERFORMANCE.md on current hardware. Fix any regressions introduced since Phase 1.
7. **Accessibility audit** — Full VoiceOver pass, keyboard-only navigation, high-contrast support, Dynamic Type.
8. **Localisation** — At minimum en, de, fr, ja (the four largest Mac developer markets).

### Exit Criteria
- App passes App Store review (if not already submitted in Phase 5).
- All PERFORMANCE.md targets met on the benchmark machine.
- VoiceOver can navigate and read the full document tree without gaps.

---

## Future Phases (Ideas, Not Committed)

These are explored further in [FEATURE-IDEAS.md](FEATURE-IDEAS.md):

- **Phase 7:** Binary formats (MessagePack, BSON, Protobuf, CBOR)
- **Phase 8:** Collaborative editing / file watching / live reload
- **Phase 9:** Plugin system for custom parsers and transformations
- **Phase 10:** iOS/iPadOS companion app
- **Phase 11:** AI-assisted features (schema inference, data summarization, natural language queries)
