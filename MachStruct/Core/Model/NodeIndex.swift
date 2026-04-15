import Foundation

/// Flat lookup structure enabling O(1) access to any node by ID.
/// Built during parse, updated incrementally on edits.
///
/// Value type — Swift COW on both internal collections means copies are cheap
/// until a mutation occurs, which is exactly what undo/redo snapshots need.
///
/// ### Storage layout (Phase 4.2)
///
/// The old `[NodeID: DocumentNode]` dictionary allocated roughly 280 B per node
/// (key + value + hash-table overhead at 75% load factor).  The new layout splits
/// this into:
///
/// - `storage: ContiguousArray<DocumentNode>` — 200 B/node, contiguous memory,
///   zero dictionary overhead, cache-friendly iteration.
/// - `positions: [NodeID: Int]` — 24 B/node (8-byte key + 8-byte value +
///   load-factor waste), purely a lookup index.
///
/// Total: ~224 B/node vs ~280 B/node — saving ~56 B per materialised node,
/// or ~56 MB for a 1 M-node document.
public struct NodeIndex: Sendable {

    // MARK: - Storage

    /// Contiguous store of all materialised nodes.
    /// Order is NOT guaranteed to be document order after mutations (swap-remove
    /// is used for O(1) deletion).  Consumers must rely on `node.childIDs` for
    /// ordered traversal, not on array position.
    private var storage: ContiguousArray<DocumentNode>

    /// Maps each NodeID → its current index in `storage`.
    /// Updated on every insert, update, and swap-remove.
    private var positions: [NodeID: Int]

    /// The root node ID for this document.
    public let rootID: NodeID

    /// Monotonically increasing version stamp.
    ///
    /// Incremented by every structural or value mutation.  Observers (e.g.
    /// `ExpandedTreeView`) watch this instead of `count` so that value edits —
    /// which don't change `count` — still trigger a flat-row rebuild.
    public private(set) var generation: UInt64 = 0

    // MARK: - Initialization

    public init(root: DocumentNode) {
        self.rootID    = root.id
        self.storage   = [root]
        self.positions = [root.id: 0]
    }

    /// Bulk initializer for constructing a NodeIndex from a pre-built node dictionary.
    /// Used by `StructuralIndex.buildNodeIndex()` after Phase 1 parsing.
    public init(rootID: NodeID, allNodes: [NodeID: DocumentNode]) {
        self.rootID = rootID
        var s = ContiguousArray<DocumentNode>()
        var p = [NodeID: Int](minimumCapacity: allNodes.count)
        s.reserveCapacity(allNodes.count)
        for (id, node) in allNodes {
            p[id] = s.count
            s.append(node)
        }
        self.storage   = s
        self.positions = p
    }

    /// Direct initializer for callers that build the flat storage in one pass.
    ///
    /// Used by `StructuralIndex.buildNodeIndex()` to avoid a second iteration
    /// when converting from a temporary dict representation.  Only visible
    /// within `MachStructCore`.
    init(rootID: NodeID,
         storage: ContiguousArray<DocumentNode>,
         positions: [NodeID: Int]) {
        self.rootID    = rootID
        self.storage   = storage
        self.positions = positions
    }

    // MARK: - Query API

    /// Total number of materialised nodes.
    public var count: Int { storage.count }

    /// The root node.
    public var root: DocumentNode? { positions[rootID].map { storage[$0] } }

    /// O(1) lookup by ID.
    public func node(for id: NodeID) -> DocumentNode? {
        positions[id].map { storage[$0] }
    }

    /// Direct children of the given node, in document order.
    public func children(of id: NodeID) -> [DocumentNode] {
        guard let n = node(for: id) else { return [] }
        return n.childIDs.compactMap { node(for: $0) }
    }

    /// Parent of the given node, or nil for the root.
    public func parent(of id: NodeID) -> DocumentNode? {
        guard let n = node(for: id), let pid = n.parentID else { return nil }
        return node(for: pid)
    }

    /// Ordered list of node IDs from root down to (and including) the given node.
    public func path(to id: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var current: NodeID? = id
        while let cid = current {
            result.append(cid)
            current = node(for: cid)?.parentID
        }
        return result.reversed()
    }

    /// Human-readable path string, e.g. `"root.items[42].name"`.
    public func pathString(to id: NodeID) -> String {
        let ids = path(to: id)
        var result = "root"
        for nodeID in ids.dropFirst() {
            guard let n = node(for: nodeID), let key = n.key else { continue }
            let parentType = n.parentID.flatMap { node(for: $0) }?.type
            if parentType == .array {
                result += "[\(key)]"
            } else {
                result += ".\(key)"
            }
        }
        return result
    }

    // MARK: - Search

    /// All nodes matching the predicate. O(n) — iterates contiguous storage.
    public func nodesMatching(predicate: (DocumentNode) -> Bool) -> [DocumentNode] {
        storage.filter(predicate)
    }

    /// All nodes at exactly the given depth. O(n).
    public func nodesAtDepth(_ depth: Int) -> [DocumentNode] {
        storage.filter { Int($0.depth) == depth }
    }

    /// All node IDs currently materialised in the index.
    ///
    /// Used by `StructDocument` eviction to find candidates for removal.
    /// Returns a snapshot copy; safe to iterate while the index is mutated.
    public var allNodeIDs: [NodeID] { Array(positions.keys) }

    // MARK: - Mutation (COW — callers receive a new index on first write)

    /// Insert a node (or overwrite if already present).
    public mutating func insert(_ node: DocumentNode) {
        if let idx = positions[node.id] {
            storage[idx] = node
        } else {
            positions[node.id] = storage.count
            storage.append(node)
        }
        generation &+= 1
    }

    /// Apply a transform to the node with the given ID. No-op if the ID is unknown.
    public mutating func updateNode(_ id: NodeID,
                                    transform: (inout DocumentNode) -> Void) {
        guard let idx = positions[id] else { return }
        transform(&storage[idx])
        generation &+= 1
    }

    /// Insert a child into the tree at the given position and register it in the
    /// parent's `childIDs`.
    public mutating func insertChild(_ node: DocumentNode,
                                     in parentID: NodeID,
                                     at index: Int) {
        if let idx = positions[node.id] {
            storage[idx] = node
        } else {
            positions[node.id] = storage.count
            storage.append(node)
        }
        guard let parentIdx = positions[parentID] else { return }
        let safeIndex = max(0, min(index, storage[parentIdx].childIDs.count))
        storage[parentIdx].childIDs.insert(node.id, at: safeIndex)
        generation &+= 1
    }

    /// Remove a node and its entire subtree.  Also removes it from its parent's
    /// `childIDs`.
    public mutating func removeNode(_ id: NodeID) {
        guard let n = node(for: id) else { return }
        if let pid = n.parentID, let parentIdx = positions[pid] {
            storage[parentIdx].childIDs.removeAll { $0 == id }
        }
        removeSubtree(id)
        generation &+= 1
    }

    /// Bulk-apply a snapshot from an `EditTransaction`.
    ///
    /// - `updates`   — nodes to add or overwrite (keyed by their ID).
    /// - `deletions` — node IDs to remove (does not recurse into children).
    ///
    /// The caller is responsible for ensuring parent `childIDs` are consistent.
    public mutating func applySnapshot(_ updates: [NodeID: DocumentNode],
                                        deletions: Set<NodeID> = []) {
        for (_, n) in updates {
            if let idx = positions[n.id] {
                storage[idx] = n
            } else {
                positions[n.id] = storage.count
                storage.append(n)
            }
        }
        for id in deletions { swapRemove(id) }
        generation &+= 1
    }

    // MARK: - Tabular detection

    /// Returns `true` when the root is an array of uniform objects.
    public func isTabular(sampleSize: Int = 10) -> Bool {
        guard let root = self.root, root.type == .array else { return false }
        let sample = children(of: root.id).prefix(sampleSize)
        guard !sample.isEmpty,
              sample.allSatisfy({ $0.type == .object }) else { return false }
        let firstKeys = children(of: sample[0].id).compactMap { $0.key }
        guard !firstKeys.isEmpty else { return false }
        return sample.allSatisfy { row in
            children(of: row.id).compactMap { $0.key } == firstKeys
        }
    }

    /// Ordered column names derived from the first row's keys.
    public var tabularColumns: [String] {
        guard let root = self.root, root.type == .array,
              let firstRow = children(of: root.id).first else { return [] }
        return children(of: firstRow.id).compactMap { $0.key }
    }

    // MARK: - Private helpers

    private mutating func removeSubtree(_ id: NodeID) {
        guard let n = node(for: id) else { return }
        for childID in n.childIDs { removeSubtree(childID) }
        swapRemove(id)
    }

    /// Evict a set of nodes from storage without modifying any parent `childIDs`.
    ///
    /// After eviction the nodes are absent from the index but their IDs remain in
    /// their parents' `childIDs` arrays.  `materializeChildrenIfNeeded` uses this
    /// to detect "not yet materialised" and re-builds them on demand.
    ///
    /// Used exclusively by `StructDocument.evictIfNeeded` — call sites must ensure
    /// the evicted IDs are not currently visible in the tree.
    public mutating func evictNodes(_ ids: Set<NodeID>) {
        guard !ids.isEmpty else { return }
        for id in ids { swapRemove(id) }
        generation &+= 1
    }

    /// O(1) removal: swap the target with the last element, update positions,
    /// then shrink the array by one.
    private mutating func swapRemove(_ id: NodeID) {
        guard let idx = positions.removeValue(forKey: id) else { return }
        let lastIdx = storage.count - 1
        if idx < lastIdx {
            let last = storage[lastIdx]
            storage[idx] = last
            positions[last.id] = idx
        }
        storage.removeLast()
    }
}
