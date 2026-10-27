# Changelog

All notable changes to MachStruct are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Large JSON files open with a fraction of the memory.** A file of 5 MB or
  more is now read straight from its bytes: opening it checks it in one pass
  and keeps only where each top-level item starts, and every other node is
  read when it is shown. A 100 MB file with 12.8 million nodes now takes
  about 65 MB after opening instead of 2.1 GB. Searching it takes about a
  second, and X-Ray now includes unsaved edits. Large CSV files will follow.

### Fixed
- **Large files used far more memory than their data needed.** Opening a
  400,000-row CSV (8 MB) took 1.7 GB, and the same rows as JSON (20 MB)
  took 1.8 GB. They now take about 720 MB and 680 MB. The index of a
  large file is smaller, and building it no longer makes temporary copies
  of it: progress was reported with a copy of every entry, and JSON files
  were parsed up to five times while a buffer grew. Large JSON files also
  open faster as a result. (#62)
- **VoiceOver read every search result control as "Previous search match".**
  The match counter and the next-match button now read as "Match 1 of 11"
  and "Next search match". (#64)
- **The toolbar search ignored edits in files of 5 MB or more.** It searched
  the file as it was opened, so an edited value couldn't be found by its new
  text, its old text still matched, and deleted entries could still be found.
  It now searches the document as edited. In files of any size, the results
  also refresh after an edit, undo or redo, without moving the selection.
  (#63)
- **Table view and Column Stats were empty for CSV files of 5 MB or more.**
  The table showed no columns and blank rows, and Column Stats reported "No
  Columns". The table now loads rows as they scroll into view, and Column
  Stats covers every row. The table is also built on the native macOS table,
  so a 400,000-row CSV switches to table view in a few seconds instead of
  freezing the window for 18 seconds, and VoiceOver reads it as a table with
  rows, cells and column headers. (#56)
- **Array items kept their old index after a delete or move.** Deleting
  `[0]` from `["a","b","c"]` left the rest labelled `[1]` and `[2]`, and
  moving an item kept its label, so the status-bar path and bookmarks could
  name the wrong item. Indices now follow the items' positions. (#57)
- **A CSV cell's path left out its row.** The status bar showed `root.name`
  for the `name` cell of every row; it now shows `root[1].name`. CSV rows are
  also numbered in the tree, and bookmarks in CSV files are found again when
  the file is reopened. (#58)
- **Bookmarks inside nested objects and arrays weren't found again** when the
  file was reopened, such as one on `root.rows[0].n`.

## [2.2.0] — 2026-10-26

Large files and YAML. Files of 5 MB or more are now handled in full: Find &
Replace, queries, saving and exporting all cover the whole file, and edits
are no longer lost while browsing. Very large files stay responsive; a
400,000-row CSV opens in seconds instead of freezing the window. YAML files
keep their comments when saved, and files with several `---` documents open.

### Added
- **YAML files with several documents open.** A file whose documents are
  separated by `---`, such as a Kubernetes manifest, used to fail with
  "Expected a single document in the stream". Each document now appears as
  an item of the root (`0`, `1`, …), and saving writes them back as
  separate documents; value edits keep comments as in single-document
  files. Exporting to JSON gives an array of the documents.

### Changed
- **VoiceOver names every control.** The document tree is announced as
  "Document tree" rather than "Sidebar"; the disclosure triangles as "Expand"
  or "Collapse" rather than "Forward"; and range rows as "Items 0 to 999".
  The Export, Bookmarks and Expand/Collapse toolbar menus have names instead
  of their icons' symbol names. The Find, Replace and jq fields, and the
  case-sensitive and regular-expression toggles, have labels instead of "Aa"
  and ".*", and decorative icons are no longer read out. In table view,
  each row is read as one item with its column names ("Row 1: id: 1,
  name: Alice"), and the raw text view is labelled. (#30)
- **Containers with more than 1,000 children are shown in ranges.** Their
  children are grouped into rows such as `[0 … 999]` and `[1000 … 1999]`,
  which open to show the items; ranges nest for very large containers. A CSV
  file with 400,000 rows used to freeze the window for 20–30 seconds on
  opening and for minutes on searching, because the tree listed every row.
  It now opens in a few seconds, and searching opens the range holding the
  match.
- **Files that fail to open now say what is wrong and where.** Instead of
  "JSON parse failed (simdjson error -1)" or "Yams.YamlError error 1", the
  message gives the line, the column and the problem — for example
  "Line 3, column 3: Badly formed object." — and shows the offending line
  with a marker under the problem. Applies to JSON, YAML and XML. (#26)
- **Saving a YAML file keeps its comments.** Value edits and key renames are
  now written into the original text in place, so comments, anchors and
  aliases, quoting and blank lines survive. Edits that add, remove or move
  entries, or that change a block scalar (`|`, `>`), still rewrite the whole
  file, which drops comments.

### Fixed
- **Jumping to a search match in a large file showed the row without its
  values.** In files with more than 50,000 nodes, the row's keys and values
  were loaded and then dropped straight away, leaving only the matching key
  with "…" as its value.
- **Find & Replace and queries now cover the whole of a large file.** In files
  of 5 MB or more, they only saw rows that had been expanded, so the match
  count was too low, Replace All left the rest unchanged, and jq queries
  returned partial results. They now work on the whole document, including
  your edits; the match count shows "Counting…" while a large file is
  searched, and it refreshes after undo and redo.
- **Deleting a key from a JSON file of 5 MB or more didn't survive saving.**
  The deleted key was written back from the original file. Deletions in large
  JSON files are now saved.
- **Exporting a large CSV or YAML file wrote empty rows.** In files of 5 MB or
  more, every row that hadn't been expanded was exported as an empty object,
  and exporting a large JSON file to YAML or CSV had the same gap. Export now
  writes the whole document, including your edits.
- **Edits to CSV and YAML files of 5 MB or more can now be saved.** 2.1.3
  refused to save them; they are now saved in full, in their own format.
- **Edits in large files could be lost while browsing.** Expanding rows in a
  large file could drop an edit made elsewhere — when memory was trimmed, or
  when the edit was made while a row was still loading. Edits are now kept.

## [2.1.3] — 2026-10-21

A data-safety release. Upgrading is strongly recommended for anyone who opens
CSV or YAML files: in earlier versions, saving one after an edit replaced its
contents with JSON.

### Fixed
- **Saving a CSV or YAML file replaced it with JSON.** After any edit, ⌘S
  wrote the document as JSON into the original `.csv` or `.yaml` file, without
  warning. CSV and YAML files are now saved in their own format, and CSV keeps
  its delimiter and its header (or lack of one). XML files can't be saved
  after editing and are left untouched. Edits to CSV or YAML files of 5 MB or
  more can't be saved yet, and saving them reports an error instead of
  writing a partial file.
- **CSV rows with more fields than the header lost the extras.** In `a,b,c`
  followed by `3,4,5,6`, the `6` was silently discarded. Surplus fields are
  now kept under generated column names (`column_4`, `column_5`, …) and are
  included when the document is exported as CSV.
- **YAML mappings with non-scalar keys lost those entries.** A complex key
  such as `? [a, b]` was skipped, along with its value. Such keys are now
  shown in flow form (`[a, b]`). Unresolved aliases, which current Yams
  never produces, are shown as `*anchor` rather than dropped.

## [2.1.2] — 2026-10-19

A correctness release. Three of these fixes concern data the app was
displaying wrongly or writing back wrongly, so upgrading is recommended for
anyone who edits and saves files.

### Fixed
- **Large files could not be navigated.** Expanding any object or array in a
  JSON file of 5 MB or more produced nothing: the arrow opened, no rows
  appeared, and the node count never moved. The tree draws a row's children by
  looking *through* the key/value pair to the value beneath it, but the lazy
  loader only ever prepared the value itself — which was already present, so it
  concluded there was nothing to do and stopped. Files below 5 MB were
  unaffected, which is why this went unnoticed.
- **Saving a JSON file reordered its keys, dropped repeated keys, and rewrote
  its numbers.** `8.7` was written back as `8.6999999999999993`, `1.0` as `1`,
  and `{"k":1,"k":2}` collapsed to a single entry. The raw view used the same
  machinery, so the altered values were visible there before anything had been
  saved. JSON is now written directly from the document rather than being
  routed through Foundation, which cannot represent key order or repeated keys
  and prints decimals at full precision. Saving a file you have not edited now
  leaves it as it was.
- **Files containing very large whole numbers would not open at all.** Any
  integer beyond 18,446,744,073,709,551,615 — Twitter-style IDs, some database
  identifiers — caused the entire document to be rejected. Such files now open,
  falling back to a parser that accepts them. This had worked in 2.1.0 and
  broke in 2.1.1.
- **The table view cut the first character off its leftmost column**, at every
  window size, so `Order ID` appeared as `rder ID`.
- **Search had no keyboard shortcut.** ⌘F now focuses the search field, and
  Find… has been added to the Edit menu.

## [2.1.1] — 2026-10-19

### Fixed
- **Object keys appeared in the wrong order, and repeated keys vanished**, in
  files under 5 MB. The structural walk for smaller files ran through
  `JSONSerialization`, whose dictionary representation can record neither the
  order keys appear in nor the same key twice — so `{"a":1,"a":2,"b":3}` was
  shown as two entries in arbitrary order, and saving wrote back the truncated
  version. Files at or above 5 MB were always correct, which meant the same
  document could read differently depending on its size. Structure now comes
  from the file's bytes at every size. As a side effect, small files parse
  slightly faster than before.
- **Opening two documents at once could show one file's data in the other, or
  hang the app.** Node identifiers were handed out from a single counter, so
  two files parsed at the same time interleaved theirs, and lookups then
  resolved to whichever node happened to occupy that slot. Search results,
  breadcrumbs, and X-Ray schemas could all report another document's contents,
  and navigating to a search result could spin the app up to gigabytes of
  memory until it was force-quit. Each document now gets its own reserved
  range, lookups verify they found the node asked for, and the affected walks
  can no longer loop indefinitely.
- **Whole-number decimals such as `1.0` were displayed and re-saved as `1`.**
  Numbers were classified by their value rather than by how they were written,
  so any float that happened to land on a whole number lost its `num` type
  badge and was silently rewritten as an integer on save.
- **The download link on machstruct.com returned a 404 for some releases.**
  The release pipeline labelled the disk image `MachStruct.dmg` but still
  uploaded it under a versioned filename, so the website's
  `releases/latest/download/MachStruct.dmg` link only worked when a copy had
  been uploaded by hand. Every release now publishes a versionless copy.

## [2.1.0] — 2026-07-09

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

[Unreleased]: https://github.com/lustech/MachStruct/compare/v2.2.0...HEAD
[2.2.0]: https://github.com/lustech/MachStruct/compare/v2.1.3...v2.2.0
[2.1.3]: https://github.com/lustech/MachStruct/compare/v2.1.2...v2.1.3
[2.1.2]: https://github.com/lustech/MachStruct/compare/v2.1.1...v2.1.2
[2.1.1]: https://github.com/lustech/MachStruct/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/lustech/MachStruct/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/lustech/MachStruct/compare/v1.0.4...v2.0.0
[1.0.4]: https://github.com/lustech/MachStruct/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/lustech/MachStruct/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/lustech/MachStruct/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/lustech/MachStruct/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/lustech/MachStruct/releases/tag/v1.0.0
