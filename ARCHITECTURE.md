# MachStruct — Architecture Overview

> A superfast structured-document viewer and editor for macOS, starting with JSON.

## 1. Vision

MachStruct is a native macOS application that opens, parses, displays, and enables editing of structured data documents — beginning with JSON and expanding to XML, YAML, and CSV. The guiding principle is **speed**: opening a 100MB JSON file should feel instant, navigation should never stutter, and the editing experience should be fluid and responsive.

## 2. Tech Stack Decision

| Layer | Technology | Rationale |
|---|---|---|
| **UI** | Swift + SwiftUI | Native macOS look and feel. Declarative UI with lazy rendering (List + OutlineGroup) gives us view recycling and on-demand child expansion for free. |
| **App framework** | SwiftUI App lifecycle | Modern, lightweight. NSDocument-based architecture for native file handling, recent files, and multi-window support. |
| **Parsing core** | Swift with C-interop to simdjson | simdjson parses JSON at gigabytes/second using SIMD instructions. We wrap it via a thin C bridge and expose a Swift-friendly API. For files under ~5MB, Foundation's JSONSerialization (recently rewritten, 5x faster) is a fine fallback. |
| **File I/O** | Memory-mapped files (mmap) | Zero-copy reads for large files. The OS pages data in on demand — we never load 100MB into a contiguous buffer. |
| **Concurrency** | Swift Concurrency (async/await, actors) | Parsing and indexing run on background actors. The UI actor is never blocked. |
| **Build** | Swift Package Manager + Xcode | SPM for dependency management; Xcode for signing, notarization, and App Store delivery. |

### Why not Rust for the core?

Rust + Swift FFI (via UniFFI or cbindgen) is a valid path and would give us the fastest possible parsing. However, for the initial phase targeting up to 100MB, simdjson via C-interop is fast enough and keeps the codebase in one language ecosystem. Rust is a viable Phase 3+ optimization if we need multi-GB support.

## 3. High-Level Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     MachStruct.app                      │
├─────────────┬───────────────────────┬───────────────────┤
│   UI Layer  │    Document Layer     │   Format Layer    │
│  (SwiftUI)  │   (NSDocument +      │  (Parser plugins) │
│             │    Data Model)        │                   │
│ ┌─────────┐ │ ┌─────────────────┐   │ ┌──────────────┐  │
│ │TreeView │ │ │StructDocument   │   │ │JSONParser    │  │
│ │Component│ │ │(internal repr.) │   │ │XMLParser     │  │
│ ├─────────┤ │ ├─────────────────┤   │ │YAMLParser    │  │
│ │Editor   │ │ │NodeIndex        │   │ │CSVParser     │  │
│ │Panel    │ │ │(fast lookup)    │   │ └──────────────┘  │
│ ├─────────┤ │ ├─────────────────┤   │                   │
│ │Search   │ │ │EditTransaction  │   │ ┌──────────────┐  │
│ │Bar      │ │ │(undo/redo)      │   │ │FileIO        │  │
│ ├─────────┤ │ └─────────────────┘   │ │(mmap + stream│  │
│ │Toolbar  │ │                       │ │ reader)      │  │
│ └─────────┘ │                       │ └──────────────┘  │
├─────────────┴───────────────────────┴───────────────────┤
│                    Platform Layer                       │
│         (macOS APIs, file system, Spotlight)             │
└─────────────────────────────────────────────────────────┘
```

## 4. Module Breakdown

### 4.1 Format Layer (`MachStructCore`)
**Responsibility:** Read bytes from disk and produce a format-agnostic node tree.

- **FileIO module** — Memory-mapped file access. Provides a `MappedFile` type that wraps `mmap`/`munmap` with safe Swift lifetime management.
- **Parser protocol** — `StructParser` protocol that each format implements: `func parse(source: MappedFile) async throws -> DocumentNode`. This is the extension point for new formats.
- **JSONParser** — Primary parser. Uses simdjson via C-interop for the hot path. Falls back to Foundation for small files or when simdjson encounters edge cases.

### 4.2 Document Layer (`MachStructDocument`)
**Responsibility:** Format-agnostic internal representation, indexing, and edit state.

- **StructDocument** — NSDocument subclass wrapping a `DocumentNode` tree. Handles open/save, dirty state, undo registration.
- **DocumentNode** — The universal internal node type (see DATA-MODEL.md). Represents objects, arrays, key-value pairs, and scalars uniformly across all formats.
- **NodeIndex** — A flat lookup structure (dictionary of node ID → node) enabling O(1) access by path or ID. Built during parse, updated incrementally on edits.
- **EditTransaction** — Groups related edits for undo/redo. Captures before/after snapshots of affected nodes.

### 4.3 UI Layer (`MachStructUI`)
**Responsibility:** Present the document and handle user interaction.

- **TreeView** — The primary view. Uses SwiftUI `List` + `OutlineGroup` for lazy, recycling tree rendering. Nodes expand on demand — collapsed subtrees cost zero memory.
- **EditorPanel** — Inline and sidebar editing. Value editing happens in-place in the tree; a detail panel shows the raw text of the selected node with syntax highlighting.
- **SearchBar** — JQ-style path queries and full-text search across keys and values. Results are highlighted in the tree with keyboard navigation.
- **Toolbar** — Format selector, collapse/expand all, view mode toggle (tree vs. raw text), stats display.

### 4.4 Platform Layer
- **Spotlight integration** — Spotlight importer plugin so JSON/XML/YAML files are indexed and searchable system-wide.
- **Quick Look** — Quick Look generator for Finder previews of supported formats.
- **Drag & drop / Services** — Accept files via drag, expose "Format JSON" as a macOS Service.

## 5. Key Design Decisions

### 5.1 Lazy Everything
The app never materializes the full node tree up front for large files. The parser produces a **structural index** (byte offsets of each node) and only fully parses node values when they become visible or are edited. This is the single most important performance decision.

### 5.2 Format-Agnostic Internal Model
All formats map to the same `DocumentNode` tree. This means every UI component, every search feature, and every editing operation works identically across JSON, XML, YAML, and CSV. New formats only need to implement the `StructParser` protocol.

### 5.3 NSDocument Architecture
Using `NSDocument` gives us native macOS document behavior for free: recent files menu, window-per-document, auto-save, version browsing (Time Machine integration), and proper dirty-state tracking.

### 5.4 Actor Isolation for Parsing
Parsing runs on a dedicated background actor. The UI actor receives a stream of `DocumentNode` updates as parsing progresses, enabling progressive rendering — the user sees the top of the tree while the rest of the file is still being parsed.

## 6. Data Flow

```
File on disk
    │
    ▼
MappedFile (mmap, zero-copy)
    │
    ▼
StructParser.parse() ──── runs on background actor
    │
    ├──▶ Structural index (byte offsets, node types)
    │         │
    │         ▼
    │    NodeIndex (flat lookup, O(1) by path)
    │
    └──▶ DocumentNode tree (lazy — values parsed on demand)
              │
              ▼
         StructDocument (NSDocument wrapper)
              │
              ▼
         SwiftUI views observe @Published properties
              │
              ├──▶ TreeView (OutlineGroup, lazy expansion)
              ├──▶ EditorPanel (selected node detail)
              └──▶ SearchBar (queries against NodeIndex)
```

## 7. Directory Structure (Target)

```
MachStruct/
├── ARCHITECTURE.md              ← you are here
├── docs/
│   ├── design/
│   │   ├── PARSING-ENGINE.md    ← parser internals
│   │   ├── UI-DESIGN.md         ← UI components and interaction
│   │   ├── DATA-MODEL.md        ← node types, indexing
│   │   └── PERFORMANCE.md       ← benchmarks, optimization strategy
│   ├── roadmap/
│   │   ├── ROADMAP.md           ← phased delivery plan
│   │   └── FEATURE-IDEAS.md     ← creative features backlog
│   └── tasks/
│       └── TASK-INDEX.md        ← AI-friendly implementation tasks
├── MachStruct/                  ← Xcode project (future)
│   ├── App/
│   ├── Core/
│   │   ├── FileIO/
│   │   ├── Parsers/
│   │   └── Model/
│   ├── UI/
│   │   ├── TreeView/
│   │   ├── Editor/
│   │   ├── Search/
│   │   └── Toolbar/
│   └── Platform/
│       ├── SpotlightImporter/
│       └── QuickLook/
├── MachStructTests/
└── Package.swift
```

## 8. Cross-References

| Topic | Document |
|---|---|
| Parser internals, simdjson integration, streaming | [PARSING-ENGINE.md](docs/design/PARSING-ENGINE.md) |
| UI component design, tree rendering, editing UX | [UI-DESIGN.md](docs/design/UI-DESIGN.md) |
| Internal node model, indexing strategy | [DATA-MODEL.md](docs/design/DATA-MODEL.md) |
| Performance targets, benchmarking plan | [PERFORMANCE.md](docs/design/PERFORMANCE.md) |
| Phased delivery plan | [ROADMAP.md](docs/roadmap/ROADMAP.md) |
| Feature ideas and differentiators | [FEATURE-IDEAS.md](docs/roadmap/FEATURE-IDEAS.md) |
| Implementation task breakdown | [TASK-INDEX.md](docs/tasks/TASK-INDEX.md) |
