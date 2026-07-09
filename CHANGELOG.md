# Changelog

All notable changes to MachStruct are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **X-Ray Mode (⇧⌘X)** — infer the implicit schema of any open document and
  show it as an expandable type tree. Field types are merged across array
  elements (`{ name: string, age: int, email: string? }`), optional fields are
  detected from presence counts, and type inconsistencies are flagged with
  exact counts (e.g. *"age — mostly int, but string in 3 of 10000"*). Runs on
  the structural index for large files (no full materialisation) and includes
  a Copy Schema action. Available from the toolbar, ⇧⌘X, and the command
  palette.

### Fixed
- **JSON numbers `0` and `1` were parsed, displayed, and re-saved as
  `false`/`true`** in files under 5 MB (and in clipboard paste and lazy value
  parsing). `NSNumber(0)`/`NSNumber(1)` cast to Swift `Bool` successfully, so
  the boolean check in four scalar-conversion paths hijacked the numbers.
  Saving an affected document silently corrupted the data. All conversions now
  go through a single `ScalarValue(jsonAny:)` that discriminates with
  `CFBooleanGetTypeID`.
- **Keys and values never resolved on JSON files ≥ 5 MB** — the simdjson
  bridge never recorded source byte offsets (a `TODO` left from P1-06), so
  lazy key/value parsing read from file offset 0 and produced empty keys,
  unparsed values, and broken search on exactly the large files the app is
  built for. A single linear token scan now aligns real byte ranges with the
  structural index.
- **Deeply nested JSON crashed the app** — two layers deep: the
  Foundation-path index walk recursed per nesting level and overflowed the
  512 KB Swift-Concurrency thread stack at roughly 200 levels (SIGBUS), and
  Apple's `JSONSerialization` itself does the same past ~700 object levels.
  The walk is now iterative, and documents nesting beyond 512 levels on the
  Foundation path are refused with a clear error instead of crashing. A
  400-level regression test and the previously-crashing
  `testPathologicalDeepDoesNotCrash` benchmark both pass.
- **Unsigned 64-bit JSON numbers ≥ 2⁶³ bit-wrapped to negative** —
  `{"big": 9223372036854775808}` displayed and re-saved as
  `-9223372036854775808`. Such values now degrade to a sign-correct float
  instead of wrapping.

## [2.0.0] — 2026-06-17

### Added — Data Workbench
- **jq query engine (⌥⌘F)** — query and reshape any open document with a real
  subset of [jq](https://jqlang.github.io/jq/): field/index/slice/iterate paths,
  pipes, `select`, `map`, comparisons, arithmetic, array/object construction, and
  builtins (`length`, `keys`, `sort_by`, `unique`, `has`, `type`, `test`, …).
  Works across JSON/YAML/CSV/XML via the unified document model.
- **Non-destructive results pane** — query output shows in a resizable bottom
  pane as an expandable tree or raw JSON, with one-click Copy and Export
  (JSON/YAML/CSV).
- **Apply to document** — path-only queries (no value construction) can be
  applied back to the open document: *Delete Matched Nodes* or *Set Value*. Each
  apply is a single undoable step via the existing transaction system.
- **Regex find & replace (⌃⌘F)** — find across keys, values, or both with
  case-sensitivity and regular-expression toggles; *Replace All* is one undoable
  step.
- **Saved & recent queries** — name and reuse jq queries; recents are remembered
  across sessions.

### Fixed
- **Open panel flashing at launch on some macOS versions** — `DocumentGroup`'s
  launch-time `openDocument` call could enter the `NSDocumentController`
  open-panel chain at any rung and fire several run-loop cycles in, after the
  previous next-cycle `suppressOpen` clear had run, letting the panel flash on
  screen. Every rung of the chain is now gated on `suppressOpen`, and the flag
  is held for 0.5 s after `applicationDidFinishLaunching`.

## [1.0.4] — 2026-04-27

### Fixed
- **App launched in German for non-English/non-German system locales** —
  v1.0.3 added a `de` localisation, but the explicit `Info.plist`
  (`GENERATE_INFOPLIST_FILE = NO`) was missing `CFBundleDevelopmentRegion`,
  so macOS could not identify the inline source strings as English. Users
  whose preferred-language list did not list English ahead of German
  (e.g. Swedish system locale) saw the app fall through to `de.lproj`.
  Added `CFBundleDevelopmentRegion = en` to restore English as the
  fallback.

## [1.0.3] — 2026-04-27

### Added
- **Command palette (⇧⌘P)** — VS Code-style fuzzy launcher over every menu/toolbar
  action, recent documents, bookmarks, and view-mode toggles.
- **Persistent bookmarks** — bookmarks now survive document close/reopen. Stored
  by path against a security-scoped file reference; stale bookmarks appear
  greyed out as `(missing)`.
- **JSON format auto-fixer** — when JSON parsing fails, a banner offers one-shot
  fixes for trailing commas, single-quoted strings, unquoted keys, and
  JS-style line comments.
- **Scalar inspector** — info chip on string scalars that detects and decodes
  base64 payloads, Unix timestamps, ISO 8601 datetimes, UUIDs, and `#RRGGBB`
  colour values; popover shows formatted breakdown.
- **German localisation (`de`)** — first non-English locale. Localisation
  infrastructure uses Xcode 15+ String Catalog (`Localizable.xcstrings`); high-traffic
  surfaces (welcome window, settings, status bar, common errors) translated.
- **Single-click row toggle** — clicking anywhere on an expandable tree row
  toggles it; ⌥-click expands the entire subtree (Finder convention). Settings
  toggle (`singleClickExpand`) lets users opt out.
- **Per-document window frame autosave** — each file remembers its window
  size and position across sessions. Welcome window remembers its frame
  separately.
- **Hover tooltips on truncated text** — full string shown on hover for
  truncated tree-row values and the status-bar breadcrumb path.
- **VoiceOver pass on core flows** — combined accessibility elements,
  meaningful labels and hints across the welcome window, tree rows, status
  bar, search controls, and clipboard banner.

### Build / Distribution
- **Mac App Store submission groundwork** — `release-appstore.yml` workflow
  archives with `APP_STORE_BUILD=YES` (Sparkle excluded), exports a signed
  `.pkg`, and validates with `altool` before publishing the artifact for
  Transporter upload. Marketing copy drafted in `marketing/` (description,
  keywords, screenshot brief). Manual portal/App Store Connect steps still
  outstanding for actual submission.

### Changed
- **Welcome window** — default size grown to 640×520 and now user-resizable.
- **Default window size** — tree-only documents open at ~900×600; tabular
  (CSV) and raw documents open at ~1200×750 to fit columns/long lines.
- **Performance SLA** — 10 MB structural-index target relaxed from 200 ms to
  250 ms after corpus correction (see Fixed). Measured 231 ms on M4 Mac mini.

### Fixed
- **Welcome window crash on first launch** — `NSHostingController.sizeThatFits`
  was passed `CGFloat.greatestFiniteMagnitude` for the height bound; because
  `WelcomeView` greedily fills available height, the call returned an
  unbounded size that violated `NSWindow`'s `CGRectContainsRect` assertion.
  Replaced with an explicit first-run content size; autosaved frames still
  win on subsequent launches.
- **Paste & Parse: each snippet now opens its own document** — pasted
  content was written to a fixed `Pasted Content.<ext>` temp path, so
  `NSDocumentController` deduped subsequent pastes against the
  already-open document. Each paste now lands in a unique per-paste
  subdirectory of the temp directory, with a sortable timestamp in the
  filename to differentiate windows in the title bar and recents menu.
- **Test corpus undersized** — `TestCorpusGenerator.generateLarge` was
  producing ~1.6 MB files instead of the documented 10 MB; `generateMedium`
  was 190 KB instead of 1 MB. Every `large.json` benchmark since the
  generator landed was running on a workload an order of magnitude smaller
  than intended. Sizes corrected.

## [1.0.2] — 2026-04-27

### Fixed
- DMG distribution: `LD_RUNPATH_SEARCH_PATHS` now lets dyld locate the
  embedded `Sparkle.framework` at launch.

## [1.0.1] — 2026-04-23

### Fixed
- QuickLook (`.appex`) and Spotlight (`.mdimporter`) extensions now built
  with hardened runtime, satisfying notarisation.
- Release pipeline: switched CI to `macos-15`, restored `exportArchive`
  flow with explicit signing style, added notarisation diagnostics.

## [1.0.0] — 2026-04-23

Initial public release. Full feature set:

### Added
- **Viewer & editor** for JSON, XML, YAML, and CSV.
- **Lazy parsing architecture (ADR-001)** — two-phase parser with shallow
  `NodeIndex` materialisation for files ≥ 5 MB; LRU eviction caps memory at
  ~150 MB resident even for 100 MB files.
- **Search** across keys and values with auto-expansion of collapsed
  ancestors and prev/next navigation.
- **Bookmarks** with toolbar menu and `⌘D` shortcut (in-session only;
  persistence in v1.1).
- **CSV stats panel** with per-column metrics.
- **Quick Look** preview extension and **Spotlight** importer.
- **Services menu** integration: "Format with MachStruct" and
  "Minify with MachStruct".
- **Clipboard watch** — auto-detects structured data on the clipboard and
  offers to open it.
- **Welcome window** with drag-and-drop, paste box, and recent files.
- **Settings** with onboarding overlay; navigation history.
- **Sparkle 2 auto-update** for DMG distribution.
- **Pretty/minify toggle** in raw text view.
- **Drag-and-drop reordering** of array elements in the tree.
- **GitHub Actions release pipeline** — notarise, DMG, GitHub Release.

[Unreleased]: https://github.com/lustech/MachStruct/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/lustech/MachStruct/compare/v1.0.4...v2.0.0
[1.0.4]: https://github.com/lustech/MachStruct/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/lustech/MachStruct/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/lustech/MachStruct/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/lustech/MachStruct/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/lustech/MachStruct/releases/tag/v1.0.0
