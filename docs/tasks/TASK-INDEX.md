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

## Phase 5: Release Engineering

> **Critical context for AI agents:** Before starting any P5 task, read ROADMAP.md §Phase 5 for the full rationale. P5-01 must land first — every other task depends on a self-contained build.

### P5-01: Vendor simdjson
- **Module:** Build / Sources/CSimdjsonBridge
- **Dependencies:** None
- **Description:** The current `CSystemSimdjson` SPM system-library target points at Homebrew (`/opt/homebrew/opt/simdjson`). Replace it entirely with the simdjson single-header amalgamation checked in to the repo. Download `simdjson.h` and `simdjson.cpp` from the [simdjson releases page](https://github.com/simdjson/simdjson/releases) (match the version currently in use). Place them under `Sources/CSimdjsonBridge/vendor/`. Update `Package.swift`: remove the `CSystemSimdjson` target and its `systemLibrary` declaration; add `simdjson.cpp` as a source in the `CSimdjsonBridge` C++ target; add any required compiler flags (`-std=c++17`, `-DSIMDJSON_EXCEPTIONS=0`). Remove all references to `CSystemSimdjson` from target dependencies.
- **Key files:** `Sources/CSimdjsonBridge/vendor/simdjson.h`, `Sources/CSimdjsonBridge/vendor/simdjson.cpp`, `Package.swift`
- **Acceptance criteria:** `swift build` succeeds on a machine with Homebrew's simdjson uninstalled (or with `PKG_CONFIG_PATH` cleared). All existing tests pass. No references to `/opt/homebrew` remain in the build log.
- **Reference docs:** ROADMAP.md §Phase 5 — Current blockers

### P5-02: Xcode App Target + Info.plist + Entitlements
- **Module:** Root / Build
- **Dependencies:** P5-01
- **Description:** Create a proper Xcode project with a macOS App target that wraps the existing SwiftUI `DocumentGroup` entry point. The `Package.swift` SwiftUI app already has everything needed — this task is about giving it the correct bundle infrastructure. Add `Info.plist` with: `CFBundleDocumentTypes` and `UTExportedTypeDeclarations` for all five formats (JSON, XML, YAML, YML, CSV); `LSMinimumSystemVersion 14.0`; `CFBundleName`, `CFBundleIdentifier` (`com.lustech.machstruct`), `CFBundleShortVersionString`. Add `MachStruct.entitlements` with `com.apple.security.app-sandbox = true` and `com.apple.security.files.user-selected.read-write = true`. Verify `StructDocument.readableContentTypes` matches the declared UTTypes.
- **Key files:** `MachStruct.xcodeproj/`, `MachStruct/App/Info.plist`, `MachStruct/App/MachStruct.entitlements`
- **Acceptance criteria:** App builds and runs from Xcode. File → Open sheet filters to .json/.xml/.yaml/.yml/.csv. Dragging any supported file onto the Dock icon opens it. `codesign -dv --entitlements - MachStruct.app` shows the sandbox entitlement. All existing tests pass.
- **Reference docs:** ROADMAP.md §Phase 5

### P5-03: App Icon
- **Module:** UI / Assets
- **Dependencies:** P5-02
- **Description:** Design and export an `AppIcon.appiconset` covering all required macOS icon sizes: 16, 32, 64, 128, 256, 512, 1024 pt at @1x and @2x (total 10 PNG files). The icon should communicate "structured document inspector" — consider motifs like nested brackets `{ }`, a magnifying glass over a tree, or a structured grid. Place the asset catalog at `MachStruct/Assets.xcassets/AppIcon.appiconset/`. Update `Contents.json` with correct filename entries.
- **Key files:** `MachStruct/Assets.xcassets/AppIcon.appiconset/`
- **Acceptance criteria:** App icon appears in the Dock, Finder, and About dialog without the default system placeholder. No missing-size warnings in Xcode's asset catalog validator. Icon passes the [App Store icon guidelines](https://developer.apple.com/design/human-interface-guidelines/app-icons) (no alpha channel, square, no rounded corners — macOS applies the mask).
- **Reference docs:** ROADMAP.md §Phase 5

### P5-04: Code Signing Configuration
- **Module:** Build
- **Dependencies:** P5-02
- **Description:** Configure Xcode signing for two distribution channels. For **direct distribution**: Developer ID Application certificate; `ExportOptions-Direct.plist` with `method = developer-id`, `hardened-runtime = true`. For **App Store**: Apple Distribution certificate; `ExportOptions-AppStore.plist` with `method = app-store`. Enable Hardened Runtime in the Xcode target build settings (required for notarization). Confirm the entitlements file is referenced in both configurations. Do not commit private keys or provisioning profiles — document where they must be placed.
- **Key files:** `ExportOptions-Direct.plist`, `ExportOptions-AppStore.plist`, `scripts/README-signing.md`
- **Acceptance criteria:** `xcodebuild archive -scheme MachStruct -archivePath build/MachStruct.xcarchive` succeeds. `xcodebuild -exportArchive … -exportOptionsPlist ExportOptions-Direct.plist` produces a signed `.app`. `codesign --verify --strict MachStruct.app` exits 0. `spctl --assess --type exec MachStruct.app` exits 0 (after notarization in P5-05).
- **Reference docs:** ROADMAP.md §Phase 5

### P5-05: Notarization + Release CI Pipeline
- **Module:** Build / CI
- **Dependencies:** P5-04
- **Description:** Create a GitHub Actions workflow (`.github/workflows/release.yml`) triggered on `v*` tag push. Pipeline steps: (1) `xcodebuild archive`, (2) `xcodebuild -exportArchive` using `ExportOptions-Direct.plist`, (3) `xcrun notarytool submit --wait` using repository secrets for Apple ID and app-specific password, (4) `xcrun stapler staple`, (5) `hdiutil create` to produce a `MachStruct-{version}.dmg`, (6) upload the DMG as a GitHub Release asset. Secrets required: `APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID`, `SIGNING_CERTIFICATE_P12`, `SIGNING_CERTIFICATE_PASSWORD`. Also add a `Makefile` target `make release` for local builds.
- **Key files:** `.github/workflows/release.yml`, `Makefile`, `scripts/notarize.sh`
- **Acceptance criteria:** Pushing `git tag v1.0.0 && git push --tags` triggers the workflow and produces a downloadable DMG on the GitHub Releases page within 15 minutes. `spctl --assess --type exec MachStruct.app` and `spctl --assess --type install MachStruct.dmg` both exit 0 on a clean macOS 14 machine (no Gatekeeper warning on double-click).
- **Reference docs:** ROADMAP.md §Phase 5

### P5-06: Sparkle Auto-Updates
- **Module:** App
- **Dependencies:** P5-05
- **Description:** Add [Sparkle 2](https://sparkle-project.org/) as an SPM dependency. In `Info.plist`, set `SUFeedURL` to the hosted `appcast.xml` URL. In `MachStructApp.swift`, instantiate `SPUStandardUpdaterController` as a `@StateObject` and expose "Check for Updates…" in the app menu. Generate an EdDSA key pair with `generate_keys` (Sparkle CLI); store the public key in `Info.plist` (`SUPublicEDKey`); store the private key securely outside the repo. Create an `appcast.xml` template and a `scripts/update-appcast.sh` helper that generates a new entry from the DMG produced by P5-05. The update check must run on a background thread and must not block launch.
- **Key files:** `Package.swift` (Sparkle dep), `MachStruct/App/MachStructApp.swift`, `MachStruct/App/Info.plist` (`SUFeedURL`, `SUPublicEDKey`), `appcast.xml`, `scripts/update-appcast.sh`
- **Acceptance criteria:** A test `appcast.xml` pointing to a fake newer version causes Sparkle's update dialog to appear within 5 seconds of launch (in debug). Removing `SUFeedURL` or hosting an empty appcast causes a graceful no-op (no crash). `SUPublicEDKey` in `Info.plist` matches the private key used to sign the appcast.
- **Reference docs:** ROADMAP.md §Phase 5, [Sparkle documentation](https://sparkle-project.org/documentation/)

### P5-07: App Store Submission Prep
- **Module:** Build / Marketing
- **Dependencies:** P5-04
- **Description:** Audit and finalise the sandbox entitlements for App Store review — `com.apple.security.app-sandbox` + `com.apple.security.files.user-selected.read-write` should be sufficient for `DocumentGroup`-based document access; confirm no `com.apple.security.temporary-exception.*` entitlements are needed. Create the App Store Connect listing: app name, subtitle, description (up to 4 000 chars), keywords (100 chars), support URL, marketing URL. Produce screenshots at both required sizes: 1280×800 (13" MacBook) and 1440×900 (15" MacBook). Set pricing (suggest free or one-time purchase — no subscriptions for a developer tool). Age rating questionnaire. `xcrun altool --validate-app` must pass before submission.
- **Key files:** `marketing/description.md`, `marketing/keywords.txt`, `marketing/screenshots/`, `MachStruct.entitlements` (App Store variant)
- **Acceptance criteria:** `xcrun altool --validate-app -f MachStruct.pkg --type osx` exits 0 with no errors or warnings. App Store Connect listing is 100% complete (green indicators on all required fields). At least 3 screenshots per device size uploaded.
- **Reference docs:** ROADMAP.md §Phase 5, [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

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
