# ADR-001: Performance Architecture for v1.0

**Status:** Proposed
**Date:** 2026-04-10
**Deciders:** @lusen

## Context

MachStruct's value proposition is speed — the roadmap's Phase 1 exit criteria demand a 100 MB JSON in < 500 ms to first paint and 60 fps tree scrolling. While simdjson's structural indexing meets these targets, three downstream bottlenecks now make the app unusable on moderately large files (≥ 10 MB) and unacceptably sluggish on files ≥ 1 MB:

**Observed symptoms (23 MB JSON, M-series Mac):**
- App frozen for 30+ seconds during file open
- ~4 GB peak resident memory
- Watchdog kills the process (exit code 9 / SIGKILL)
- General UI sluggishness during tree navigation

**Root causes identified (in severity order):**

1. **Main-actor blocking during load.** `StructDocument.load(data:)` runs three heavy operations synchronously on the main actor: `data.write(to:)` (disk I/O), `parser.buildIndex()` (parse), and `si.buildNodeIndex()` (O(n) dictionary construction). *Partially fixed in commit 0b24fb5 — these now run in `Task.detached`. But the total wall-clock time is unchanged.*

2. **Eager full-tree materialisation.** `buildNodeIndex()` creates a `DocumentNode` struct and inserts it into a `[NodeID: DocumentNode]` dictionary for every node in the file, regardless of whether the user will ever view it. Per-node memory footprint:

   | Structure | Bytes / node |
   |---|---|
   | `MSIndexEntry` (C, freed after parse) | 32 |
   | `IndexEntry` (Swift) | 100–120 |
   | `DocumentNode` in `[NodeID: …]` dict | 184–228 |
   | `childIDsByParent` temporary | 38 (amortised) |
   | **Peak total** | **~390** |
   | **Steady-state** (NodeIndex only) | **~210** |

   For a 23 MB dense JSON (~1.5 M nodes): 1.5 M × 390 ≈ **585 MB peak**. Files with many small keys inflate this further due to Swift `String` heap allocations. Reported 4 GB suggests 10–15 M entries.

3. **`ExpandedTreeView.flatRows` recomputed on every state change.** The computed property runs a DFS over all visible nodes to produce `[FlatRow]`. It re-fires on *every* SwiftUI body re-evaluation — not just expansion changes, but also selection changes and scroll triggers. For large expanded trees, this produces noticeable frame drops.

4. **`SyntaxHighlighter` compiles regex on every call.** Each `paint()` invocation constructs a new `NSRegularExpression`. For a JSON highlight pass this means 5+ regex compilations per invocation. If the user toggles pretty/minify or resizes the font, the entire highlight path reruns.

5. **`Text(AttributedString)` for raw view.** SwiftUI's `Text` does not virtualise — it lays out the entire attributed string in one pass. Files near the 150 KB highlight limit can cause multi-second layout stalls.

6. **Services handler deadlock risk.** `DispatchSemaphore.wait(for:)` blocks the calling thread. macOS calls service providers on the main thread, so `processService()` blocks the main actor while a `Task` awaits the parser actor. If the parse touches `@MainActor` state, this deadlocks. Even without deadlock, a large paste freezes the UI for the parse duration.

## Decision

Adopt a **tiered loading strategy** with three performance tiers based on file size, plus targeted fixes for UI-layer bottlenecks. All work is gated as a v1.0 blocker.

### Tier boundaries

| Tier | File size | Strategy | Target: time-to-first-paint | Target: memory |
|---|---|---|---|---|
| **Small** | < 5 MB | Eager (current) | < 200 ms | < 100 MB |
| **Medium** | 5–50 MB | Background + partial tree | < 500 ms | < 500 MB |
| **Large** | > 50 MB | Progressive streaming | < 1 s (visible nodes) | < 1 GB |

## Options Considered

### Option A: Progressive / lazy NodeIndex (recommended)

| Dimension | Assessment |
|---|---|
| Complexity | Medium–High |
| Risk | Medium (touches NodeIndex, the core data model) |
| Scalability | Excellent — memory proportional to visible nodes |
| Scope of code change | `StructuralIndex`, `NodeIndex`, `StructDocument`, `ExpandedTreeView` |

**Approach:**
- Keep `StructuralIndex.entries: [IndexEntry]` as the canonical flat data. It's compact (100–120 B/node) and already in document order.
- Build `NodeIndex` only for the **visible window** — root children plus any expanded subtrees. Expansion of a node triggers on-demand `DocumentNode` construction for its children from the flat entries.
- Introduce a `LazyNodeIndex` wrapper (or extend `NodeIndex`) that holds a reference to `StructuralIndex` and materialises `DocumentNode` values lazily:
  - `node(for:)` → check `nodesById`; if miss, look up in `StructuralIndex` by a `[NodeID: Int]` offset map, build `DocumentNode` in-place.
  - `children(of:)` → walk `entries` from parent's offset, collecting children. Cache in `nodesById`.
- `StructuralIndex` gets a `[NodeID: Int]` lookup table (8 + 4 = 12 bytes/entry, built in O(n) during parse, replaces the need for the full dictionary).

**Pros:**
- Memory proportional to visible tree, not file size (50–100 visible nodes = < 100 KB)
- Structural index is compact and already built
- `parseProgressively` API already exists — can feed UI while background parse continues
- Edits still work via the existing `EditTransaction` → `NodeIndex.applySnapshot` path (materialise the subtree being edited)

**Cons:**
- Every `node(for:)` call now has a cache-miss path. Hot path must remain O(1) (dictionary lookup).
- `SearchEngine.search` traverses all nodes — needs to work directly on `StructuralIndex.entries` rather than `NodeIndex`
- Edit transactions that touch non-materialised nodes need a materialise-on-write path

### Option B: Virtual NodeIndex via memory-mapped flat array

| Dimension | Assessment |
|---|---|
| Complexity | High |
| Risk | High (custom binary format, unsafe pointers) |
| Scalability | Excellent — zero-copy, constant memory |
| Scope of code change | New `FlatNodeStore`, all consumers of `NodeIndex` |

**Approach:**
- After simdjson produces `[MSIndexEntry]`, write a compact binary array to a temp file. Memory-map it. `NodeIndex` becomes a thin view over the mmap'd data.
- No Swift structs, no dictionary. All node data accessed via pointer arithmetic.

**Pros:** Minimal memory, maximum speed.
**Cons:** Fragile, unsafe, hard to debug. Edits require a copy-on-write layer. Massive refactor. Over-engineered for v1.0.

### Option C: Keep eager materialisation, just optimise memory layout

| Dimension | Assessment |
|---|---|
| Complexity | Low |
| Risk | Low |
| Scalability | Poor — still O(n) memory |
| Scope of code change | `DocumentNode`, `NodeIndex` |

**Approach:**
- Replace `[NodeID: DocumentNode]` with a flat `[DocumentNode]` array + `[NodeID: Int]` index (saves ~40 B/node dictionary overhead).
- Use `ContiguousArray` for `childIDs`.
- Intern short string keys in a shared `StringTable`.

**Pros:** Low risk, modest memory reduction (~30%).
**Cons:** Still O(n) memory. A 100 MB file with 10 M nodes still uses 1.5+ GB.

## Trade-off Analysis

Option A is the sweet spot: it brings memory from O(n) to O(visible) while reusing existing infrastructure (`StructuralIndex`, `parseProgressively`). It's the standard approach for large-data viewers (Instruments, Wireshark, VS Code's large file mode all use variants of this pattern).

Option B is the theoretically optimal solution but inappropriate for a v1.0 where stability matters more than pushing the ceiling from 100 MB to 10 GB. It can be explored for v2.0.

Option C is a useful complement to Option A (interning keys and compacting arrays helps even the lazy path) but insufficient on its own.

**Recommendation:** Option A as the primary strategy, with select elements of Option C (string interning, flat array compaction) applied where they're easy wins.

## Implementation Plan

### Phase 1: Immediate fixes (v1.0 blocker — do first)

These are targeted, low-risk fixes that address the worst user-visible symptoms.

**1.1 — Cache `NSRegularExpression` in `SyntaxHighlighter`**
- Replace per-call `NSRegularExpression(pattern:)` with `nonisolated(unsafe) static let` cached instances.
- Eliminates 5+ regex compilations per highlight call.
- ~30 lines changed, `SyntaxHighlighter.swift` only.

**1.2 — Cache `flatRows` in `ExpandedTreeView`**
- Add `@State private var cachedFlatRows: [FlatRow] = []`.
- Recompute only on `expandedIDs` or `nodeIndex` changes (not selection, not scroll trigger).
- Avoids redundant DFS traversals on every row tap.
- ~20 lines changed, `ExpandedTreeView.swift` only.

**1.3 — Batch `expandPath` state updates**
- `ContentView.expandPath(to:in:)` currently calls `expandedIDs.insert()` in a loop.
- Collect IDs into a local `Set`, then `expandedIDs.formUnion()` once.
- Eliminates N intermediate SwiftUI re-renders when expanding a deep path.

**1.4 — Move Services handler off main thread**
- `processService()` blocks the calling thread with `DispatchSemaphore`.
- Dispatch to a serial background queue so the main actor is never blocked.
- Eliminates the deadlock risk.

**1.5 — Cap navigation history**
- `navHistory: [NodeID]` grows unboundedly.
- Cap at 100 entries; drop oldest when exceeded.

### Phase 2: Lazy NodeIndex (v1.0 blocker — core architecture change)

**2.1 — Add `[NodeID: Int]` offset map to `StructuralIndex`**
- After building `entries`, construct a `[NodeID: Int]` mapping each entry's `id` to its array index.
- 12 bytes/entry. For 1 M nodes: 12 MB (vs 210 MB for full `NodeIndex`).

**2.2 — Introduce `LazyNodeIndex`**
- Wraps `StructuralIndex` + offset map + a materialisation cache (`[NodeID: DocumentNode]`).
- `node(for:)`: check cache → miss → build from `entries[offset]` → insert into cache → return.
- `children(of:)`: for a given `parentID`, scan `entries` from the parent's offset forward (children follow parent in document order) collecting entries with matching `parentID`. Cache the result.
- Conforms to the same API as `NodeIndex` (protocol extraction or direct replacement).

**2.3 — Wire `ExpandedTreeView` to lazy loading**
- `rootTreeNodes` calls `children(of: rootID)` → materialises only root children.
- `appendRows` for expanded nodes materialises their children on expansion.
- Collapsed subtrees remain as lightweight `IndexEntry`s.

**2.4 — Adapt `SearchEngine` to work on `StructuralIndex` directly**
- `SearchEngine.search` currently traverses `NodeIndex` (materialised nodes).
- Rewrite to iterate `StructuralIndex.entries` directly, resolving keys/values lazily from byte offsets.
- For the simdjson path, scalar values require `parseValue(entry:from:)` — run in batches on a background task so search remains responsive.

**2.5 — Adapt edit operations**
- `EditTransaction.applying(to:)` currently takes a `NodeIndex`.
- Extend to accept `LazyNodeIndex`; materialise the affected subtree before applying.
- Undo snapshots capture only the materialised delta.

### Phase 3: UI layer performance (v1.0 — can ship without, nice-to-have)

**3.1 — Replace `Text(AttributedString)` with `NSTextView` wrapper**
- Create `HighlightedTextView: NSViewRepresentable` wrapping an `NSTextView`.
- `NSTextView` virtualises text layout natively. Files up to 10+ MB render smoothly.
- The 150 KB highlight limit can be raised or removed.

**3.2 — Use `parseProgressively` for the loading UI**
- Show a progress bar with entry count during parse.
- Emit the first batch of root-level nodes to the tree immediately.
- Remaining nodes stream in while the user can already browse the top level.

### Phase 4: Memory compaction (v1.1 — complementary)

**4.1 — String interning for keys**
- JSON objects often repeat the same key across thousands of entries (e.g., `"id"`, `"name"`, `"type"`).
- Introduce a `StringTable` (dictionary of `String → Int` offsets) and store `StringTable.Index` instead of `String` in `DocumentNode.key`.
- Estimated savings: 40–60% reduction in key-string heap allocations.

**4.2 — Flat `ContiguousArray<DocumentNode>` storage**
- Replace `[NodeID: DocumentNode]` with `ContiguousArray<DocumentNode>` + `[NodeID: Int]` index.
- Eliminates dictionary overhead (~36 bytes/entry) and improves cache locality.

**4.3 — Eviction policy for `LazyNodeIndex` cache**
- LRU or depth-based eviction: when the cache exceeds a threshold (e.g., 50 K nodes), evict nodes that are deep in collapsed subtrees.
- Keeps memory bounded even when the user expands and collapses many subtrees.

## Consequences

**What becomes easier:**
- Opening files 10–100 MB with acceptable responsiveness and memory use.
- Future support for files > 100 MB (progressive streaming path exists).
- Raw-view rendering of large files (NSTextView virtualisation).

**What becomes harder:**
- Every `NodeIndex` consumer must handle the lazy-miss case (or we extract a protocol so both `NodeIndex` and `LazyNodeIndex` are transparent).
- Edit operations on non-materialised subtrees need an explicit materialise step.
- Debugging memory issues — two data representations (flat entries + cached nodes) can diverge.

**What we'll need to revisit:**
- The 5 MB Foundation / simdjson threshold may need tuning once lazy loading is in place.
- The `parseProgressively` API currently sends *all* entries in batches; with lazy loading, it could stop after root + first-level children and defer the rest.
- Performance benchmarks (`ParseBenchmarks.swift`) need new tests for `LazyNodeIndex` construction time and cache-hit rates.

## Performance Targets (v1.0)

| Metric | Current | Target |
|---|---|---|
| 10 MB JSON time-to-first-paint | 2–5 s (frozen) | < 500 ms |
| 23 MB JSON time-to-first-paint | 30+ s (killed) | < 2 s |
| 23 MB JSON peak memory | ~4 GB | < 500 MB |
| 100 MB JSON opens without crash | No (SIGKILL) | Yes |
| Tree selection / expand latency | 50–200 ms | < 16 ms (60 fps) |
| Raw view toggle (1 MB file) | 200–500 ms | < 100 ms |

## Action Items

### Must-have for v1.0

1. [ ] **Phase 1.1** — Cache regex in `SyntaxHighlighter` (est: 30 min)
2. [ ] **Phase 1.2** — Cache `flatRows` in `ExpandedTreeView` (est: 1 hr)
3. [ ] **Phase 1.3** — Batch `expandPath` state updates (est: 15 min)
4. [ ] **Phase 1.4** — Move Services handler off main thread (est: 30 min)
5. [ ] **Phase 1.5** — Cap navigation history (est: 15 min)
6. [ ] **Phase 2.1** — Offset map in `StructuralIndex` (est: 1 hr)
7. [ ] **Phase 2.2** — Implement `LazyNodeIndex` (est: 4 hr)
8. [ ] **Phase 2.3** — Wire tree view to lazy loading (est: 2 hr)
9. [ ] **Phase 2.4** — Adapt search to `StructuralIndex` (est: 2 hr)
10. [ ] **Phase 2.5** — Adapt edit operations (est: 2 hr)
11. [ ] **Benchmarks** — Add `LazyNodeIndex` perf tests, verify targets (est: 1 hr)

### Nice-to-have for v1.0

12. [ ] **Phase 3.1** — `NSTextView` wrapper for raw view (est: 2 hr)
13. [ ] **Phase 3.2** — Progressive loading UI (est: 3 hr)

### v1.1

14. [ ] **Phase 4.1** — String interning (est: 3 hr)
15. [ ] **Phase 4.2** — Flat array storage (est: 4 hr)
16. [ ] **Phase 4.3** — LRU eviction (est: 2 hr)
