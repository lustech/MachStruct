# MachStruct Roadmap

> Phased delivery plan from MVP to full structured-document toolkit.

## Phase Overview

| Phase | Codename | Focus | Timeline Estimate |
|---|---|---|---|
| **Phase 1** | Foundation | JSON viewer with core tree UI | ✅ Complete |
| **Phase 2** | Editor | JSON editing, undo, save | ✅ Complete |
| **Phase 3** | Formats | XML, YAML, CSV support | ✅ Complete |
| **Phase 4** | Power Tools | Search, diff, conversion, plugins | 🔄 In Progress |
| **Phase 5** | Release Engineering | simdjson vendoring, Xcode target, signing, notarization, Sparkle, App Store | 🔄 In Progress |
| **Phase 6** | Polish | Settings, onboarding, Quick Look, Spotlight, accessibility, localisation | 🔄 In Progress |

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
1. ~~**Full-text search**~~ ✅ **DONE** *(P4-01)* — `.searchable` field in window toolbar (Cmd+F). `SearchEngine` scans all keys and scalar values in DFS document order. Yellow highlight on all matches; amber on the active match. `"N of M"` counter + ↑↓ chevron navigation pill in toolbar. Background `Task.detached` keeps UI fluid on large files.
2. ~~**Auto-expand on search nav**~~ ✅ **DONE** *(P4-02)* — Replaced `List(data:children:)` with `ExpandedTreeView` (flat `[FlatRow]` array + explicit `expandedIDs: Set<NodeID>`). When navigating to a match, `expandPath(to:in:)` opens every collapsed ancestor; `ScrollViewReader` scrolls the row into view.
3. **Path queries** — JQ-style expressions for targeted navigation and filtering.
3. **Diff view** — Compare two documents or two versions of the same document. Highlight added, removed, and changed nodes.
4. **Schema validation** — Validate JSON against JSON Schema, XML against XSD/DTD.
5. ~~**Format/minify**~~ ✅ **DONE** *(P4-04)* — Segmented picker in the raw text toolbar switches between pretty-printed and minified output. Re-serializes asynchronously; `rawPretty: Bool` state persists across document edits.
6. ~~**Bookmarks**~~ ✅ **DONE** *(P4-03)* — `bookmark` toolbar menu lists bookmarked nodes by path string; Cmd+D toggles bookmark on the current selection; `bookmark.fill` icon shown in NodeRow. In-session only (path-based persistence planned).
7. **History** — Recently viewed nodes within a document, like browser history.
8. **Clipboard watch** — Detect JSON/XML on the clipboard and offer to open in MachStruct.
9. **Syntax highlighting** in raw text view (JSON, XML, YAML, CSV) — deferred from Phase 3.
10. **CSV column statistics** — Type distribution, unique count, min/max per column — deferred from Phase 3.
11. ~~**Drag-and-drop reordering**~~ ✅ **DONE** *(P4-05)* — `ForEach.onMove` in `ExpandedTreeView` with sibling-index translation from flat to parent-relative positions. Restricted to `.array` children; dispatches `EditTransaction.moveArrayItem` through `@Environment(\.commitEdit)`.

### Exit Criteria
- Search returns results in < 1s for 100MB files.
- Diff correctly identifies all changes between two 10MB files.

---

## Phase 5: Release Engineering

**Goal:** Get MachStruct into users' hands as a self-contained, signed, auto-updating macOS app — via direct notarized DMG first, App Store second.

### Current blockers (must fix before any release)

All three pre-release blockers are now resolved:

1. ~~**`simdjson` is a Homebrew system library**~~ ✅ **DONE (P5-01)** — Replaced with simdjson v3.12.3 vendored amalgamation under `Sources/CSimdjsonBridge/vendor/`. No Homebrew required. `swift build` succeeds on any machine.
2. ~~**No Xcode app target**~~ ✅ **DONE (P5-02)** — `MachStruct.xcodeproj` created with proper `Info.plist`, `PRODUCT_BUNDLE_IDENTIFIER`, and all five UTTypes declared via `LSItemContentTypes`. `public.yaml` registered via `UTImportedTypeDeclarations`. App launches from Xcode with Dock icon, menu bar, and Open panel. See implementation notes below.
3. ~~**No signing or sandboxing configuration**~~ ✅ **DONE (P5-04)** — `MachStruct.entitlements` (App Sandbox + user-selected read-write), `ExportOptions-Direct.plist`, `ExportOptions-AppStore.plist`, and `ENABLE_HARDENED_RUNTIME = YES` are all in place. See `scripts/README-signing.md`.

### Distribution channels

| Channel | When | Notes |
|---|---|---|
| **Notarized DMG** | v1.0 | Fastest path; no review; Sparkle handles updates |
| **Mac App Store** | v1.1+ | After v1.0 proves stable; broader discovery |

### Deliverables

### Implementation notes (P5-02 — lessons learned)

- **SPM executable targets do not reliably embed `Info.plist`** — Xcode auto-generates a minimal plist and ignores ours regardless of file placement. A proper `.xcodeproj` with `GENERATE_INFOPLIST_FILE = NO` and `INFOPLIST_FILE = MachStruct/App/Info.plist` is required.
- **`LSItemContentTypes` is mandatory for `DocumentGroup`** — `CFBundleTypeExtensions` alone is not enough on modern macOS. Each `CFBundleDocumentTypes` entry must include an `LSItemContentTypes` array with the actual UTI string (`public.json`, `public.xml`, etc.).
- **`public.yaml` must be imported** — It is not guaranteed to be registered system-wide on macOS 14. Add a `UTImportedTypeDeclarations` entry so `UTType(filenameExtension: "yaml")` resolves correctly.
- **`NSApp` is nil at `App.init()` time** — Do not call `NSApp.setActivationPolicy()` from the SwiftUI `App` struct initialiser; it crashes. With a proper xcodeproj + Info.plist the activation policy is set automatically and no workaround is needed.

---

1. ~~**Vendor simdjson**~~ ✅ **DONE** *(P5-01)* — Replaced `CSystemSimdjson` with the simdjson v3.12.3 single-header amalgamation (`simdjson.h` + `simdjson.cpp`) under `Sources/CSimdjsonBridge/vendor/`. Homebrew dependency eliminated. 332 tests pass. Debug builds use a relaxed 6 000 ms threshold; release SLA is unchanged at 1 500 ms.

2. ~~**Xcode app target + Info.plist**~~ ✅ **DONE** *(P5-02)* — `MachStruct.xcodeproj` created; see implementation notes above. `Info.plist` declares all five UTTypes (JSON, XML, YAML, YML, CSV) for `CFBundleDocumentTypes`. Entitlements file grants `com.apple.security.files.user-selected.read-write` (sandbox-compatible with `ReferenceFileDocument`).

3. ~~**App icon**~~ ✅ **DONE** *(P5-03)* — `AppIcon.appiconset` at all required sizes (16 → 1024 pt, @1x + @2x) in `MachStruct/Assets.xcassets`. Design: deep cobalt→electric-blue gradient, white document with folded top-right corner, structural lines, amber speed-chevrons (»).

4. ~~**Code signing configuration**~~ ✅ **DONE** *(P5-04)* — `MachStruct.entitlements` (App Sandbox + user-selected read-write), `ExportOptions-Direct.plist` (Developer ID, Hardened Runtime), `ExportOptions-AppStore.plist`. `ENABLE_HARDENED_RUNTIME = YES` in xcodeproj. Full guide in `scripts/README-signing.md`.

5. ~~**Notarization pipeline**~~ ✅ **DONE** *(P5-05)* — `.github/workflows/release.yml` triggers on `v*` tag push. `macos-14` runner: imports Developer ID cert into temp keychain → archives → exports → `xcrun notarytool submit --wait` → asserts "Accepted" → `xcrun stapler staple` → `codesign --verify` + `spctl --assess` → `hdiutil create UDZO` → `gh release create --draft`. Six Actions secrets required (see TASK-INDEX.md §P5-05). Release is created as a draft for review before publishing.

6. ~~**Sparkle auto-updates**~~ ✅ **DONE** *(P5-06)* — Sparkle 2 added as SPM dependency. `SPUStandardUpdaterController` held on `AppDelegate`; "Check for Updates…" wired into app menu. `SUFeedURL` → `https://machstruct.lustech.se/appcast.xml`, `SUPublicEDKey` placeholder ready for `generate_keys`. `scripts/appcast.xml` template + `scripts/README-sparkle.md` release guide included.

7. **App Store submission prep** *(P5-07)* — Sandbox entitlements audited (only `user-selected.read-write` required for `DocumentGroup`). App Store Connect listing: screenshots at 1280×800 and 1440×900, description, keywords, age rating, pricing. `xcrun altool --validate-app` clean before submission.

### Sequencing (updated)

```
✅ P5-01 (vendor simdjson)
✅ P5-02 (Xcode target + Info.plist)
✅ P5-03 (app icon)
✅ P5-04 (signing config + entitlements)
         │
         ▼
✅ P5-05 (notarize CI — GitHub Actions DMG pipeline)
         │
         ▼
✅ P5-06 (Sparkle auto-updates)
         │
         ▼
    ship v1.0 DMG
         │
         ▼
    P5-07 (App Store submission)
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
2. ~~**Welcome / launch window**~~ ✅ **DONE** *(P6-02)* — Dedicated welcome window replaces the bare system Open panel on launch. Drop zone (drag JSON/XML/YAML/CSV), "Open File…" button, recent files list. Implemented via `NSWindow` + `NSHostingController` (not SwiftUI `Window` scene — avoids macOS 14 `DocumentGroup` ordering issues). Re-shown on Dock click (`applicationShouldHandleReopen`). Cmd+Shift+0 shortcut.
3. ~~**Paste raw text**~~ ✅ **DONE** *(P6-03)* — Inline `TextEditor` in the welcome window's left panel (window grown to 560×460). User pastes any JSON/XML/YAML/CSV text, clicks Parse, and the content opens as an untitled document window titled "Pasted Content". `FormatDetector` auto-detects the format silently; routes through temp-file path so `StructDocument` required no changes.
4. **Onboarding** — First-launch welcome sheet highlighting key features and pointing to docs.
5. ~~**Quick Look plugin**~~ ✅ **DONE** *(P6-05)* — `MachStructQuickLook.appex` (Quick Look Preview Extension) embedded in the main app. `PreviewViewController: QLPreviewingController` renders UTF-8 file text in a read-only `NSTextView`; files > 256 KB are truncated with a notice. Supports JSON, XML, YAML, CSV.
6. ~~**Spotlight importer**~~ ✅ **DONE** *(P6-06)* — `MachStructSpotlight.mdimporter` bundle embedded in `Contents/Library/Spotlight/`. `GetMetadataForFile` populates `kMDItemTextContent` (≤ 1 MB), `kMDItemKind`, and `kMDItemContentType` so all keys and string values are full-text indexed by Spotlight.
7. **macOS Services** — "Format JSON" and "Minify JSON" in the system Services menu.
8. **Performance audit** — Profile every target from PERFORMANCE.md on current hardware. Fix any regressions introduced since Phase 1.
9. **Accessibility audit** — Full VoiceOver pass, keyboard-only navigation, high-contrast support, Dynamic Type.
10. **Localisation** — At minimum en, de, fr, ja (the four largest Mac developer markets).

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
