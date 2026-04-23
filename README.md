# MachStruct

> A native macOS structured-document viewer and editor built for speed.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/swift-5.10-orange)
![License](https://img.shields.io/badge/license-MIT-green)

MachStruct opens, navigates, edits, and converts large JSON, XML, YAML, and CSV files in under a second. A 100 MB JSON file is structurally indexed in **under 500 ms** and displayed as a live, expandable, editable tree — no loading spinners, no frozen UI.

---

## Features

### Viewing & Navigation
- **Full-text search** — Cmd+F with highlighted matches and ↑↓ navigation
- **Navigation history** — Cmd+[ / Cmd+] to step back and forward through visited nodes
- **Bookmarks** — Cmd+D to bookmark any node; toolbar menu lists them by path
- **Tree view** — expandable outline with drag-and-drop reordering
- **Table view** — sticky-header spreadsheet for CSV files and uniform arrays of objects
- **Raw text view** — syntax-highlighted with pretty/minify toggle
- **CSV column statistics** — per-column breakdown: row count, unique count, detected type, min/max
- **Status bar** — node count, file size, format, and full path to the selected node

### Editing
- **Inline value editing** — click any scalar to edit; type auto-detected
- **Key renaming** — double-click a key label
- **Add / delete nodes** — via context menu
- **Array reordering** — drag-and-drop or context menu
- **Copy / paste** — copy any subtree as JSON; paste into containers
- **Unlimited undo/redo** — Cmd+Z / Cmd+Shift+Z
- **Save** — Cmd+S with dirty-state indicator

### Formats
- **JSON** — simdjson two-phase parse (structural index + lazy value decode)
- **XML** — libxml2 SAX parser with namespace and attribute badges
- **YAML** — Yams/libyaml with anchor, scalar-style, and tag badges
- **CSV** — auto-delimiter detection; auto-header detection; RFC 4180 quoting
- **Auto-detection** — format sniffed from file content, not just extension
- **Export / convert** — export as JSON, YAML, or CSV in one click

### macOS Integration
- **Welcome window** — drop zone, paste raw text, recent files
- **Quick Look** — Space bar in Finder previews supported files
- **Spotlight** — keys and string values are full-text indexed
- **macOS Services** — "Format with MachStruct" and "Minify with MachStruct" in the Services menu
- **Clipboard watch** — detects structured data on the clipboard and offers one-click open
- **Auto-updates** — background update checks via Sparkle

---

## Performance

Built for large files from the ground up:

- **Zero-copy I/O** — memory-mapped files via `mmap`; a 100 MB file uses < 5 MB of resident memory
- **Lazy parsing** — only nodes you expand are fully parsed
- **LRU eviction** — cold nodes are evicted above 50K to keep memory bounded

| File | Size | Nodes | Index time |
|---|---|---|---|
| large.json | 10 MB | 210 K | ~112 ms |
| huge.json | 100 MB | 710 K | ~264 ms |

Benchmarked on an M1 Mac, release build.

---

## Requirements

| Dependency | Version | Notes |
|---|---|---|
| macOS | 14.0+ | |
| Xcode | 15+ | For building the app |
| simdjson | 3.12.3 | Vendored — no install required |
| Yams | 5.4+ | Resolved via SPM |
| Sparkle | 2.x | Resolved via SPM |

---

## Getting Started

### Open in Xcode (recommended)

```bash
git clone https://github.com/lustech/MachStruct.git
cd MachStruct
open MachStruct.xcodeproj
```

Press **Cmd+R** to build and run. Drop any `.json`, `.xml`, `.yaml`, `.yml`, or `.csv` file onto the welcome window, paste raw text, or click "Open File...".

### Command line (library + tests only)

```bash
swift build -c release
swift test
```

> `swift build` builds the core library. For the full macOS app, open `MachStruct.xcodeproj` in Xcode.

---

## Architecture

MachStruct uses a two-phase parsing architecture:

1. **Phase 1 (Structural Index)** — the parser scans the entire file and builds a flat array of byte offsets, types, depths, and parent IDs. No values are decoded yet. This is fast (~100 bytes per node).

2. **Phase 2 (Lazy materialisation)** — when a node is expanded in the UI, its children are built from the structural index and their values parsed from the memory-mapped file. Most nodes in large files are never touched.

```
MachStruct/
├── Sources/CSimdjsonBridge/     C++ bridge wrapping simdjson
├── MachStruct/
│   ├── Core/                    Platform-independent library
│   │   ├── Model/               DocumentNode, NodeIndex, ScalarValue, EditTransaction
│   │   ├── FileIO/              MappedFile (mmap + madvise)
│   │   ├── Parsers/             JSON, XML, YAML, CSV parsers
│   │   └── Serializers/         JSON, YAML, CSV serializers + format converter
│   └── App/                     SwiftUI app, document lifecycle, UI views
├── MachStructQuickLook/         Quick Look extension
├── MachStructSpotlight/         Spotlight importer
└── MachStructTests/             Test suite
```

---

## Contributing

1. Fork the repo and create a feature branch
2. Add tests alongside your code
3. Run `swift test` and confirm all tests pass before opening a PR
4. Follow the existing conventions:
   - **Actors** for parser/registry state
   - **`nonisolated`** for stateless helpers
   - **COW structs** for model types (`NodeIndex`, `DocumentNode`)
   - **`Sendable`** on everything that crosses concurrency boundaries

---

## License

MIT - see [LICENSE](LICENSE) for details.
