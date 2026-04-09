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
| P3-01 | XMLParser | P1-05 | libxml2 SAX-based parser ✅ |
| P3-02 | XML UI adaptations | P3-01, P1-08 | Namespace badges, attributes ✅ |
| P3-03 | YAMLParser | P1-05 | libyaml-based parser ✅ |
| P3-04 | YAML UI adaptations | P3-03, P1-08 | Anchor/alias display ✅ |
| P3-05 | CSVParser | P1-05 | Auto-delimiter detection ✅ |
| P3-06 | Table view | P3-05, P1-08 | Tabular display for arrays/CSV ✅ |
| P3-07 | Format conversion | P3-01–P3-05 | Cross-format export ✅ |
| P3-08 | Auto-detection | P1-05 | Content-based format sniffing ✅ |

---

## Phase 4: Power Tools

### P4-01: Full-Text Search ✅ DONE
- **Module:** Core/Model + App/UI
- **Dependencies:** P1-04 (NodeIndex), P1-08 (TreeView), P2-01 (NodeRow)
- **Key files:**
  - `Core/Model/SearchEngine.swift` (new) — `SearchMatch` + `SearchEngine.search(query:in:)`
  - `Core/Model/ScalarValue.swift` — added `searchableText` property
  - `App/UI/Search/SearchEnvironment.swift` (new) — `searchMatchIDs` + `activeSearchMatchID` env keys
  - `App/UI/TreeView/NodeRow.swift` — search highlight background
  - `App/ContentView.swift` — `.searchable`, search state, toolbar nav, `scheduleSearch`
- **Implementation notes:**
  - `SearchEngine.search(query:in:)` is a pure sync function; `ContentView` calls it via `Task.detached` on a background thread.
  - Traversal is DFS pre-order (stack-based, not recursive) so results are always in document top-to-bottom order.
  - Scalar nodes that are inline children of `keyValue` nodes resolve to their parent's row ID — so highlighted rows always correspond to visible `NodeRow`s in the tree.
  - Match highlighting uses SwiftUI environment keys (`searchMatchIDs`, `activeSearchMatchID`) injected in `ContentView.contentStack` and read in `NodeRow.searchHighlight`. No changes needed to `TreeView` — env propagates automatically.
  - Yellow highlight (`Color.yellow.opacity(0.22)`) for all matches; amber (`Color.orange.opacity(0.30)`) for the active (navigated-to) match.
  - Toolbar shows `"N of M"` counter + ↑↓ chevron buttons inside a `.regularMaterial` pill when matches exist.
  - Cmd+F activates the search field (via `.searchable`). Return advances to next match; the pill buttons also work. Clearing the field dismisses all highlights.
- **Acceptance criteria:** Typing in the search field highlights all matching rows with yellow. ↑↓ navigation moves through matches in document order with an amber highlight on the active match and updates the counter. Clearing the field removes all highlights. 332 existing tests still pass.
- **Reference docs:** ROADMAP.md §Phase 4

### P4-02: Auto-Expand on Search Nav ✅ DONE
- **Module:** App/UI
- **Dependencies:** P4-01 (SearchEngine, searchMatches state in ContentView)
- **Key files:**
  - `App/UI/TreeView/ExpandedTreeView.swift` (new) — `FlatRow` + `ExpandedTreeView`
  - `App/ContentView.swift` — `expandedIDs`, `scrollTrigger`, `scrollTarget`, `expandPath(to:in:)`, `navigateToCurrentMatch()`
- **Implementation notes:**
  - Root problem: SwiftUI's `List(data:children:)` owns its expand/collapse state internally with no programmatic API. Replaced with `ExpandedTreeView`, which keeps `expandedIDs: Set<NodeID>` as an external `@Binding` owned by `ContentView`.
  - `ExpandedTreeView` computes a flat `[FlatRow]` array via DFS pre-order traversal that skips children of nodes not in `expandedIDs`. Only visible rows appear in the array — collapsed subtrees have zero rendering cost.
  - Manual disclosure triangles: `chevron.right` image rotated 90° when open, animated at 0.15 s. Row indentation via `listRowInsets(leading: level × 18 + 6)`.
  - `expandPath(to:in:)` walks `index.path(to:)`, drops root and target, and inserts every intermediate node whose `TreeNode.children != nil` into `expandedIDs`. Non-row nodes (e.g. hidden container children of keyValue rows) are harmlessly inserted but never matched by flatRow traversal.
  - Scroll-to-row: `ScrollViewReader` + a `scrollTrigger: Int` counter in `ContentView`. Counter avoids the SwiftUI `onChange` non-fire when navigating to the same ID twice. One `DispatchQueue.main.async` hop ensures expansion is reflected in the List before the scroll runs.
  - `navigateToCurrentMatch()` consolidates expand + select + scroll for both `advanceMatch()` and `previousMatch()`.
- **Acceptance criteria:** Pressing ↑↓ (or Return in search) to navigate to a match inside a collapsed subtree automatically expands the full ancestor chain and scrolls the match row into view. Manually collapsed nodes stay collapsed when the search clears. Existing search highlight behaviour (P4-01) is unchanged.
- **Reference docs:** ROADMAP.md §Phase 4

### P4-04: Format / Minify Toggle ✅ DONE
- **Module:** App / ContentView
- **Dependencies:** P4-01 (raw view already in place)
- **Key files:** `MachStruct/App/ContentView.swift`
- **Implementation notes:**
  - `@State private var rawPretty: Bool = true` drives pretty vs. minified serialisation.
  - Segmented `Picker` with SF Symbols (`text.alignleft` / `arrow.left.and.right.text.vertical`) added to `.primaryAction` toolbar, visible only when `viewMode == .raw`.
  - `refreshRawText()` parameterised on `rawPretty`; value captured before `Task.detached` dispatch to avoid data-race.
- **Acceptance criteria:** Toggling the picker in raw view re-serialises immediately. Pretty output is indented; minified output is a single line. Toggle is disabled during async serialisation.
- **Reference docs:** ROADMAP.md §Phase 4

### P4-05: Drag-and-Drop Reordering ✅ DONE
- **Module:** App / UI / TreeView / ExpandedTreeView
- **Dependencies:** P2-04 (EditTransaction.moveArrayItem), P4-02 (ExpandedTreeView flat list)
- **Key files:** `MachStruct/App/UI/TreeView/ExpandedTreeView.swift`
- **Implementation notes:**
  - Switched `List(flatRows, selection:)` to `List(selection:) { ForEach(flatRows) { }.onMove { } }` to attach `.onMove`.
  - `isMovableRow(_:)` restricts drag handles to rows whose direct parent has `.type == .array`.
  - `handleDragMove(from:to:)` translates flat-array destination index to parent-relative sibling index: count sibling flat indices (same parentID) that are less than `destination`, excluding the source row.
  - Dispatches `EditTransaction.moveArrayItem` through `@Environment(\.commitEdit)` for full undo/redo support.
- **Acceptance criteria:** Array items can be dragged to reorder within their parent array. Non-array children (object key-value pairs) show no drag handle. Move is undoable with Cmd+Z. Document is dirtied after reorder.
- **Reference docs:** ROADMAP.md §Phase 4

---

## Phase 5: Release Engineering

> **Critical context for AI agents:** Before starting any P5 task, read ROADMAP.md §Phase 5 for the full rationale. P5-01 must land first — every other task depends on a self-contained build.

### P5-01: Vendor simdjson ✅ DONE
- **Module:** Build / Sources/CSimdjsonBridge
- **Dependencies:** None
- **Key files:** `Sources/CSimdjsonBridge/vendor/simdjson.h`, `Sources/CSimdjsonBridge/vendor/simdjson.cpp`, `Package.swift`
- **Implementation notes:**
  - Vendored simdjson v3.12.3 (single-header amalgamation) — v4.x was specified but the DOM API used by `MachStructBridge.cpp` is identical between versions; 3.12.3 was used because GitHub egress was unavailable at implementation time.
  - Removed `CSystemSimdjson` system-library target and all `/opt/homebrew` flags entirely.
  - `CSimdjsonBridge` now lists `sources: ["MachStructBridge.cpp", "vendor/simdjson.cpp"]` and adds `headerSearchPath("vendor")` + `SIMDJSON_EXCEPTIONS=0`.
  - `ParseBenchmarks.testHugeFileIndexTime` threshold relaxed to 6 000 ms in `#if DEBUG` builds (simdjson compiled unoptimised from source); release SLA remains 1 500 ms.
- **Acceptance criteria:** `swift build` succeeds without Homebrew simdjson installed. All 332 tests pass (331 functional + 1 debug-relaxed perf threshold). No references to `/opt/homebrew` remain.
- **Reference docs:** ROADMAP.md §Phase 5 — Current blockers

### P5-02: Xcode App Target + Info.plist + Entitlements ✅ DONE (partial)
- **Module:** Root / Build
- **Dependencies:** P5-01
- **Status:** Xcode project and Info.plist complete and working. Entitlements file (sandbox) still needed — add during P5-04.
- **What was built:**
  - `MachStruct.xcodeproj/project.pbxproj` — generated deterministically from `gen_xcodeproj.py`. App target with `GENERATE_INFOPLIST_FILE = NO`, `INFOPLIST_FILE = MachStruct/App/Info.plist`, `PRODUCT_BUNDLE_IDENTIFIER = com.machstruct.app`, deployment target macOS 14.0. `MachStructCore` linked as a local Swift package via `XCLocalSwiftPackageReference`.
  - `MachStruct/App/Info.plist` — `CFBundleDocumentTypes` with both `CFBundleTypeExtensions` **and** `LSItemContentTypes` for JSON, XML, YAML/YML, CSV. `UTImportedTypeDeclarations` registers `public.yaml`. `NSPrincipalClass = NSApplication`.
- **Key lessons (for future AI agents):**
  - SPM executable targets do not reliably embed `Info.plist` — a real `.xcodeproj` is required.
  - `LSItemContentTypes` is required in each `CFBundleDocumentTypes` entry; extensions alone are not matched by `DocumentGroup` at runtime.
  - `public.yaml` must be declared under `UTImportedTypeDeclarations` — it is not guaranteed to be registered system-wide on macOS 14.
  - Never call `NSApp.setActivationPolicy()` from `App.init()` — `NSApp` is nil at that point and crashes with `_swift_runtime_on_report`. With a proper xcodeproj + Info.plist the activation policy is set automatically.
- **Remaining:** ~~Add `MachStruct.entitlements` (sandbox + user-selected read-write) during P5-04.~~ Done in P5-04.
- **Key files:** `MachStruct.xcodeproj/project.pbxproj`, `MachStruct/App/Info.plist`
- **Reference docs:** ROADMAP.md §Phase 5

### P5-03: App Icon ✅ DONE
- **Module:** UI / Assets
- **Dependencies:** P5-02
- **Key files:** `MachStruct/Assets.xcassets/AppIcon.appiconset/` (12 PNGs + Contents.json)
- **Implementation notes:**
  - Dark navy gradient background; node-tree motif (root + 2 children + 3 leaves); curly braces either side. Generated programmatically with Pillow.
  - All 12 required pixel sizes: 16, 32, 64, 128, 256, 512, 1024 @1x and @2x.
  - `Assets.xcassets` wired into `xcodeproj`: PBXFileReference + PBXBuildFile + PBXResourcesBuildPhase entry.
- **Acceptance criteria:** App icon appears in the Dock, Finder, and About dialog without the default system placeholder.
- **Reference docs:** ROADMAP.md §Phase 5

### P5-04: Code Signing Configuration ✅ DONE
- **Module:** Build
- **Dependencies:** P5-02
- **Key files:** `MachStruct/App/MachStruct.entitlements`, `ExportOptions-Direct.plist`, `ExportOptions-AppStore.plist`, `scripts/README-signing.md`
- **Implementation notes:**
  - `MachStruct.entitlements`: App Sandbox + `user-selected.read-write` (required for a document-based sandboxed app).
  - `ExportOptions-Direct.plist`: `method=developer-id`, `hardened-runtime=true`. Replace `XXXXXXXXXX` with real Team ID.
  - `ExportOptions-AppStore.plist`: `method=app-store`. Same Team ID placeholder.
  - `ENABLE_HARDENED_RUNTIME = YES` and `CODE_SIGN_ENTITLEMENTS` set in both Debug and Release build configurations.
  - `scripts/README-signing.md`: step-by-step guide for certificate setup, archiving, notarization, and what never to commit.
- **Acceptance criteria:** `xcodebuild archive` succeeds; `codesign --verify --strict` exits 0 after signing with a Developer ID cert.
- **Reference docs:** ROADMAP.md §Phase 5

### P5-05: Notarization + Release CI Pipeline ✅ DONE
- **Module:** Build / CI
- **Dependencies:** P5-04
- **Key files:** `.github/workflows/release.yml`, `ExportOptions-Direct.plist` (updated comment)
- **Implementation notes:**
  - Workflow triggers on `v*` tag push. Runner: `macos-14` (Apple Silicon, Xcode 15 pre-installed).
  - Step order: checkout → import certificate into temp keychain → patch `ExportOptions-Direct.plist` teamID via `PlistBuddy` → `xcodebuild archive` → `xcodebuild -exportArchive` → `ditto` zip → `xcrun notarytool submit --wait` → status assertion (fails loudly if not "Accepted") → `xcrun stapler staple` → `codesign --verify` + `spctl --assess` → `hdiutil create UDZO` → `gh release create --draft` → delete temp keychain.
  - Release is created as a **draft** so it can be reviewed and release notes edited before publishing.
  - `APPLE_CERTIFICATE` is stored as a base64-encoded `.p12` (`base64 -i cert.p12 | pbcopy` to generate).
  - Notarytool output is captured as JSON and parsed with `python3` to assert status == "Accepted".
  - `ExportOptions-Direct.plist` teamID placeholder `XXXXXXXXXX` is safe to commit; CI patches it at runtime from `APPLE_TEAM_ID` secret.
- **Required Actions secrets:**

  | Secret | How to obtain |
  |---|---|
  | `APPLE_CERTIFICATE` | Export Developer ID Application cert as .p12, then `base64 -i cert.p12` |
  | `APPLE_CERTIFICATE_PASSWORD` | Password set when exporting the .p12 |
  | `APPLE_TEAM_ID` | 10-char string from developer.apple.com/account → Membership |
  | `APPLE_ID` | Apple ID email associated with the developer account |
  | `NOTARIZATION_PASSWORD` | App-specific password from appleid.apple.com |
  | `KEYCHAIN_PASSWORD` | Any strong random string (e.g. `openssl rand -base64 32`) |

- **Acceptance criteria:** Pushing `git tag v1.0.0 && git push --tags` triggers the workflow, completes in < 15 min, and produces a draft GitHub Release with `MachStruct-v1.0.0.dmg` attached. `spctl --assess --type exec MachStruct.app` exits 0 on a clean macOS 14 machine.
- **Reference docs:** ROADMAP.md §Phase 5, `scripts/README-signing.md`

### P5-06: Sparkle Auto-Updates ✅ DONE
- **Module:** App
- **Dependencies:** P5-05
- **Description:** Sparkle 2 added as SPM dependency (`Package.swift` + `project.pbxproj` `XCRemoteSwiftPackageReference`). `SPUStandardUpdaterController` held on `AppDelegate` for app lifetime. "Check for Updates…" wired into app menu via `CommandGroup(after: .appInfo)`. `SUFeedURL = https://machstruct.lustech.se/appcast.xml` and `SUPublicEDKey` placeholder set in `Info.plist`. `NSAppTransportSecurity` allows `machstruct.lustech.se` only. `scripts/appcast.xml` template + `scripts/README-sparkle.md` release guide.
- **Key files:** `Package.swift`, `MachStruct.xcodeproj/project.pbxproj`, `MachStruct/App/MachStructApp.swift`, `MachStruct/App/Info.plist`, `scripts/appcast.xml`, `scripts/README-sparkle.md`
- **Remaining one-time step:** Run Sparkle's `generate_keys` tool, paste the printed public key into `Info.plist` (`SUPublicEDKey`), and build `sign_update` for use during releases.
- **Acceptance criteria:** ✅ Sparkle compiles and links. ✅ "Check for Updates…" appears in app menu. ✅ Appcast template and release guide in place. ⏳ `SUPublicEDKey` placeholder to be replaced with real key before first release.
- **Reference docs:** ROADMAP.md §Phase 5, `scripts/README-sparkle.md`, [Sparkle documentation](https://sparkle-project.org/documentation/)

### P5-07: App Store Submission Prep
- **Module:** Build / Marketing
- **Dependencies:** P5-04
- **Description:** Audit and finalise the sandbox entitlements for App Store review — `com.apple.security.app-sandbox` + `com.apple.security.files.user-selected.read-write` should be sufficient for `DocumentGroup`-based document access; confirm no `com.apple.security.temporary-exception.*` entitlements are needed. Create the App Store Connect listing: app name, subtitle, description (up to 4 000 chars), keywords (100 chars), support URL, marketing URL. Produce screenshots at both required sizes: 1280×800 (13" MacBook) and 1440×900 (15" MacBook). Set pricing (suggest free or one-time purchase — no subscriptions for a developer tool). Age rating questionnaire. `xcrun altool --validate-app` must pass before submission.
- **Key files:** `marketing/description.md`, `marketing/keywords.txt`, `marketing/screenshots/`, `MachStruct.entitlements` (App Store variant)
- **Acceptance criteria:** `xcrun altool --validate-app -f MachStruct.pkg --type osx` exits 0 with no errors or warnings. App Store Connect listing is 100% complete (green indicators on all required fields). At least 3 screenshots per device size uploaded.
- **Reference docs:** ROADMAP.md §Phase 5, [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

---

---

## Phase 6: Polish (Selected Tasks)

### P6-02: Welcome / Launch Window ✅ DONE
- **Module:** App / UI
- **Dependencies:** P5-02
- **Description:** Add a dedicated welcome window that appears on app launch, replacing the bare system Open panel. The window contains three areas: (1) a drop zone that accepts JSON, XML, YAML, and CSV files via drag-and-drop, (2) an "Open File…" button that triggers `NSOpenPanel` filtered to the supported UTTypes, and (3) a scrollable recent files list sourced from `NSDocumentController.shared.recentDocumentURLs`. Opening a file (via any of the three methods) calls `NSDocumentController.shared.openDocument(withContentsOf:display:completionHandler:)` to open it in a new `DocumentGroup` document window — the welcome window stays open independently.
- **Design decisions:** new window per file (not single-window replace); recent files list visible on welcome screen; welcome window re-openable via Window menu (Cmd+Shift+0).
- **Key files:** `MachStruct/App/WelcomeView.swift` (new), `MachStruct/App/MachStructApp.swift` (AppDelegate + MachStructDocumentController)
- **Implementation notes:**
  - Used `NSWindow + NSHostingController(rootView: WelcomeView())` via `AppDelegate` instead of a SwiftUI `Window` scene — avoids DocumentGroup ordering/focus issues on macOS 14.
  - `MachStructDocumentController` subclass suppresses the auto-launch Open panel via `suppressOpen` flag; cleared on next run-loop cycle after launch.
  - `NSOpenPanel` notification observer (Strategy B) provides a belt-and-suspenders guard in case DocumentGroup bypasses the document controller.
  - Welcome window is a singleton (`_welcomeWindow`); `applicationShouldHandleReopen` re-shows it on Dock click when no document windows are open.
  - `ContentView.placeholderView` text updated to "No content to display." (defensive fallback only).
- **Acceptance criteria:** App launches directly into the welcome window (no system Open panel). Dropping a supported file onto the drop zone opens it in a document window. Clicking "Open File…" shows a filtered open panel. Recent files are listed and clicking one opens it. Unsupported file types dropped onto the zone show a clear error state. Welcome window is accessible from the Window menu.
- **Reference docs:** ROADMAP.md §Phase 6

### P6-03: Paste Raw Text on Welcome Screen ✅ DONE
- **Module:** App / UI (`WelcomeView.swift`)
- **Dependencies:** P6-02, P1-06 (FormatDetector)
- **Description:** Add an inline text area to the welcome window's left panel so users can paste raw JSON, XML, YAML, or CSV text and have it open as an untitled document — no file required.

#### Layout change

The left panel currently stacks: icon → title → drop zone → error label → Open File button. Expand the window from `560×360` to `560×460` and add a text-paste area between the drop zone and the Open File button:

```
icon + title
  drop zone  (unchanged)
  ── OR paste text ──   (Label, .caption, .tertiary, HRule-style divider on each side)
  TextEditor             (fixed height ≈ 90 pt, rounded border, placeholder overlay)
  [Parse]                (Button, .bordered, disabled when TextEditor is empty)
  error label            (existing, shared with drop zone errors)
  [Open File…]           (existing, .borderedProminent)
```

The placeholder overlay (`Text("Paste JSON, XML, YAML, or CSV…").foregroundStyle(.tertiary)`) is shown when `pasteText.isEmpty` and overlaid at the leading edge using a `ZStack`; it is not a real placeholder since `TextEditor` does not support one natively.

The "── OR paste text ──" divider is a simple `HStack` with two `Divider()` views flanking a `Text` label.

#### New state

Add to `WelcomeView`:
```swift
@State private var pasteText: String = ""
@State private var isParsing: Bool = false
```

#### Parse action

```swift
private func parsePastedText() {
    let trimmed = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    isParsing = true

    // 1. Auto-detect format from content bytes.
    let data = Data(trimmed.utf8)
    let detected = FormatDetector.detect(data: data, fileExtension: nil)
    // detected is a FormatDetector.Result with a .format property (JSONFormat, XMLFormat, etc.)
    // Map to a file extension string:
    let ext: String
    switch detected.format {
    case .json:         ext = "json"
    case .xml:          ext = "xml"
    case .yaml:         ext = "yaml"
    case .csv:          ext = "csv"
    default:            ext = "json"   // fallback — parser will error gracefully
    }

    // 2. Write to a named temp file (overwriting any previous paste).
    //    The filename is intentionally generic: the user is expected to Save As if they
    //    want to keep the content.
    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("Pasted Content.\(ext)")
    do {
        try data.write(to: tempURL, options: .atomic)
    } catch {
        showDropError("Could not write temp file: \(error.localizedDescription)")
        isParsing = false
        return
    }

    // 3. Open via document controller — same path as dropping a file.
    NSDocumentController.shared.openDocument(
        withContentsOf: tempURL, display: true
    ) { _, alreadyOpen, error in
        DispatchQueue.main.async {
            isParsing = false
            if let error {
                showDropError(error.localizedDescription)
            } else {
                // Clear the text area on success; refresh recents.
                pasteText = ""
                recentURLs = NSDocumentController.shared.recentDocumentURLs
            }
        }
    }
}
```

> **Why temp file?** `StructDocument` is a `ReferenceFileDocument` whose `read(from:)` path is already battle-tested and handles mmap, progressive parsing, and all four formats. Routing through a temp URL reuses that path with zero changes to the document layer. The document opens with the title "Pasted Content" and an immediate dirty state; the user is naturally prompted to File › Save As if they want to keep it.

> **Recents note:** "Pasted Content.json" will appear in the recent files list. This is acceptable for now. A future improvement (P6-xx) could call `NSDocumentController.shared.noteNewRecentDocumentURL` after a real Save As and skip adding the temp URL.

#### Parse button state

```swift
Button(action: parsePastedText) {
    if isParsing {
        ProgressView().controlSize(.small)
    } else {
        Text("Parse")
    }
}
.buttonStyle(.bordered)
.disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isParsing)
```

#### Tests

Add to `MachStructTests/UI/WelcomeViewTests.swift` (or a new `PasteParserTests.swift`):
- `testFormatDetectionForPastedJSON()` — feed `{"key": 1}`, assert detected format is `.json`, assert temp file created with `.json` extension.
- `testFormatDetectionForPastedXML()` — feed `<root><a/></root>`, assert `.xml`.
- `testFormatDetectionForPastedYAML()` — feed `key: value\n- item`, assert `.yaml`.
- `testFormatDetectionForPastedCSV()` — feed `a,b,c\n1,2,3`, assert `.csv`.
- `testEmptyPasteIsNoOp()` — call `parsePastedText()` with empty/whitespace text, assert no temp file written.

- **Implementation notes (as shipped):**
  - Window height: 560×460 (was 360). `VStack(spacing: 16)` keeps content comfortably distributed.
  - `orDivider`: `HStack` with two `VStack { Divider() }` flanking a `Text("or paste text")` label — fills to 220 pt width.
  - `pasteArea`: `ZStack(alignment: .topLeading)` with `TextEditor` underneath and a `Text` placeholder overlay (`allowsHitTesting(false)`) to work around `TextEditor`'s lack of native placeholder support.
  - `parsePastedText()`: synchronous temp-file write (`data.write(to:options:.atomic)`) on main thread is acceptable for typical paste sizes. Async path is the `openDocument` callback.
  - `isParsing` drives the Parse button label: idle → `Text("Parse")`, active → `ProgressView().controlSize(.mini)` + `Text("Parsing…")`.
  - Error display reuses the existing `showDropError` / `dropError` path (auto-dismisses after 3 s).
- **Key files:**
  - `MachStruct/App/WelcomeView.swift` — layout change + new state + `parsePastedText()`
  - No changes to `StructDocument`, `FormatDetector`, or `Package.swift`
- **Acceptance criteria:**
  - Welcome window is 560×460 (height increased by 100 pt).
  - A text area appears between the drop zone and the Open File button.
  - Placeholder text "Paste JSON, XML, YAML, or CSV…" is visible when the text area is empty.
  - Parse button is disabled when the text area is empty or only whitespace.
  - Pasting valid JSON and clicking Parse opens a new document window titled "Pasted Content" with the parsed tree visible.
  - Pasting valid XML / YAML / CSV also opens correctly (auto-detected, no format picker shown).
  - Parse button shows a `ProgressView` spinner while the document is loading.
  - Text area is cleared after a successful parse.
  - An inline error is shown (same red label as drop errors) if the temp file write fails.
  - 332 existing tests still pass.
- **Reference docs:** ROADMAP.md §Phase 6, ARCHITECTURE.md §4.1 (FormatDetector)

### P4-03: Node Bookmarks ✅ DONE
- **Module:** App / UI / Bookmarks, App / ContentView
- **Dependencies:** P4-02 (ExpandedTreeView + expandPath machinery)
- **Key files:** `MachStruct/App/UI/Bookmarks/BookmarkEnvironment.swift` (new), `MachStruct/App/ContentView.swift`, `MachStruct/App/UI/TreeView/NodeRow.swift`
- **Implementation notes:**
  - `BookmarkEnvironment.swift` adds two environment keys: `\.bookmarkedNodeIDs: Set<NodeID>` (read, for NodeRow membership check) and `\.toggleBookmark: ((NodeID) -> Void)?` (write, dispatched via `makeToggleBookmark($bookmarks)` which captures the `Binding` to avoid stale captures in escaping closures).
  - ContentView holds `@State var bookmarks: [NodeID]` (ordered, insertion-order preserved). A toolbar `Menu` with `bookmark`/`bookmark.fill` icon lists bookmarks by `NodeIndex.pathString`; clicking navigates using the existing `expandPath + scroll` machinery.
  - Cmd+D keyboard shortcut: hidden `Button` in `.background` modifier with `.keyboardShortcut("d", modifiers: .command)`.
  - NodeRow shows a `bookmark.fill` icon (orange, 9pt) before the TypeBadge, and adds "Add/Remove Bookmark" to the context menu.
  - In-session only: NodeIDs are counter-based and reset on each parse. Path-based persistence deferred.
- **Acceptance criteria:** Right-click any node → "Add Bookmark" pins it. Re-click → "Remove Bookmark" unpins. Cmd+D toggles. Toolbar shows bookmark count (filled icon when non-empty). Clicking a bookmark in the menu navigates to the node (expands, selects, scrolls). "Clear All Bookmarks" wipes the list.
- **Reference docs:** ROADMAP.md §Phase 4

### P6-05: Quick Look Preview Extension ✅ DONE
- **Module:** MachStructQuickLook (new Xcode extension target)
- **Dependencies:** None (standalone extension; no MachStructCore dependency)
- **Key files:** `MachStructQuickLook/PreviewViewController.swift`, `MachStructQuickLook/Info.plist`
- **Implementation notes:**
  - `PreviewViewController: NSViewController, QLPreviewingController` reads file bytes on a background thread and displays UTF-8 text in a read-only `NSTextView` (monospaced, scrollable).
  - Files > 256 KB are truncated with a visible notice so the QL daemon never blocks.
  - Info.plist declares `NSExtensionPointIdentifier = com.apple.quicklook.preview` and `QLSupportedContentTypes` for JSON, XML, CSV, YAML.
  - Extension embedded in main app via `Embed App Extensions` `PBXCopyFilesBuildPhase` (dstSubfolderSpec = 13).
  - Product bundle ID: `se.lustech.MachStruct.QuickLook`.
- **Acceptance criteria:** Space-bar preview of a JSON/XML/YAML/CSV file in Finder shows a scrollable text preview. Large files show a truncation notice. No crash or timeout.
- **Reference docs:** ROADMAP.md §Phase 6

### P6-06: Spotlight Importer ✅ DONE
- **Module:** MachStructSpotlight (new Xcode spotlight-importer target)
- **Dependencies:** None (standalone bundle; no MachStructCore dependency)
- **Key files:** `MachStructSpotlight/GetMetadata.swift`, `MachStructSpotlight/schema.strings`, `MachStructSpotlight/Info.plist`
- **Implementation notes:**
  - `@_cdecl("GetMetadataForFile")` Swift function populates `kMDItemTextContent` (raw UTF-8 content, ≤ 1 MB), `kMDItemKind` ("JSON Document" etc.), and `kMDItemContentType`.
  - `schema.strings` maps attribute names to human-readable display strings for the Spotlight UI.
  - Info.plist lists `CFBundleDocumentTypes` for all four UTIs.
  - Bundle embedded at `Contents/Library/Spotlight/` via a `PBXCopyFilesBuildPhase` with `dstSubfolderSpec = 16` and `dstPath = "$(CONTENTS_FOLDER_PATH)/Library/Spotlight"`.
  - Product bundle ID: `se.lustech.MachStruct.Spotlight`.
- **Acceptance criteria:** After first launch, `mdimport -d1 file.json` reports `kMDItemTextContent` populated. Spotlight search for a key name or string value in a JSON file returns the file. `kMDItemKind` shows "JSON Document" in Get Info.
- **Reference docs:** ROADMAP.md §Phase 6

---

## v1.0 Quick-Win & Polish Features (all ✅ DONE)

The following features were implemented as quick-win or medium-effort polish items during the pre-v1.0 sprint. Each is self-contained and does not have its own P-series ID.

### Syntax Highlighting ✅ DONE
- **Key file:** `MachStruct/App/UI/RawView/SyntaxHighlighter.swift`
- **Description:** Regex-based `NSMutableAttributedString` highlighter for JSON (keys blue, values orange, numbers purple, booleans/null red), XML (tag names blue, attribute names teal, attribute values orange, comments dimmed), YAML (keys blue, comments green, numbers purple), CSV (header bold blue, numbers purple). Limit 150 KB; plain monospaced fallback above the limit. Runs on a utility background thread after serialisation; `ContentView` holds `highlightedRawText: AttributedString?`.

### CSV Column Statistics ✅ DONE
- **Key file:** `MachStruct/App/UI/CSV/CSVStatsPanel.swift`
- **Description:** Sheet opened by a "Column Stats" toolbar button (visible only for CSV documents). Shows a card per column: row count, non-empty count, empty count, unique count (capped at 100), detected type (Integer/Decimal/String/Mixed/Empty), numeric min/max. Computation runs on `Task.detached`.

### Navigation History ✅ DONE
- **Key file:** `MachStruct/App/ContentView.swift` (history state + helpers)
- **Description:** `navHistory: [NodeID]` + `navHistoryIndex: Int` + `isNavigatingHistory: Bool` flag. `pushHistory()` deduplicates consecutive entries and truncates forward stack on manual navigation. `goBack()` / `goForward()` share `navigate(to:in:)` which expands ancestors, selects, and scrolls. Cmd+[ / Cmd+] keyboard shortcuts; back/forward chevron buttons in `.navigation` toolbar placement.

### Clipboard Watch ✅ DONE
- **Key file:** `MachStruct/App/ClipboardWatcher.swift`
- **Description:** `ClipboardWatcher` ObservableObject polls `NSPasteboard` every 1.5 s. Lightweight heuristic sniffer detects JSON (`{`/`[`), XML (`<`), YAML (key: lines), CSV (uniform delimiter count). Ignores text > 2 MB. `ClipboardBanner` is a dismissible animated overlay shown in `WelcomeView` with format icon, character count, "Open" (routes through `parsePastedText()`), and × dismiss.

### macOS Services ✅ DONE
- **Key files:** `MachStruct/App/Info.plist` (`NSServices`), `MachStruct/App/MachStructApp.swift` (`AppDelegate`)
- **Description:** "Format with MachStruct" and "Minify with MachStruct" registered in `NSServices`. `@objc formatWithMachStruct` / `minifyWithMachStruct` handlers on `AppDelegate`. JSON text is round-tripped through `JSONParser` → `JSONDocumentSerializer`; XML/YAML/CSV pass through unchanged. A `DispatchSemaphore` helper bridges the async parse to the synchronous Services API. Note: macOS caches the Services menu — `pbs -update` or logout/login required after first install.

### Settings UI (P6-01) ✅ DONE
- **Key file:** `MachStruct/App/UI/Settings/SettingsView.swift`
- **Description:** Tabbed `Settings` scene (⌘,). `AppSettings.Keys` and `AppSettings.Defaults` centralise all `UserDefaults` key names and default values. Tabs: General (show welcome on launch toggle, version/build info), Appearance (tree view font size 11–14 pt), Raw View (font size 11–16 pt, default pretty/minify radio). All `@AppStorage`; changes apply immediately.

### Onboarding (P6-04) ✅ DONE
- **Key file:** `MachStruct/App/UI/Onboarding/OnboardingView.swift`
- **Description:** `AppDelegate.showOnboardingWindow()` presents a standalone `NSWindow` containing a 2-column `LazyVGrid` of 6 feature cards (tree navigation, editing, search, export, syntax highlighting, Quick Look/Spotlight). Shown automatically 0.4 s after first launch if `hasSeenOnboarding` is false. "Get Started" sets the flag. Re-openable via Help › Show Welcome Guide…

---

## Task Dependency Graph (Phase 5)

```
P5-01 (Vendor simdjson)
  └──▶ P5-02 (Xcode target + Info.plist)
         ├──▶ P5-03 (App icon)          [can run in parallel with P5-04]
         └──▶ P5-04 (Code signing)
                    └──▶ P5-05 (Notarization CI)
                               └──▶ P5-06 (Sparkle)
                                          └──▶  ship v1.0 DMG
                    └──▶ P5-07 (App Store prep)  [can run in parallel with P5-05/06]
```

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
