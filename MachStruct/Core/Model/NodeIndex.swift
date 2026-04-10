import Foundation

/// Flat lookup structure enabling O(1) access to any node by ID.
/// Built during parse, updated incrementally on edits.
///
/// Value type — Swift's COW on the internal Dictionary means copies are cheap
/// until a mutation occurs, which is exactly what undo/redo snapshots need.
public struct NodeIndex: Sendable {

    private var nodesById: [NodeID: DocumentNode]

    /// The root node ID for this document.
    public let rootID: NodeID

    /// Total number of nodes in the index.
    public var count: Int { nodesById.count }

    /// Monotonically increasing version stamp.
    ///
    /// Incremented by every structural or value mutation.  Observers (e.g.
    /// `ExpandedTreeView`) watch this instead of `count` so that value edits —
    /// which don't change `count` — still trigger a flat-row rebuild and prevent
    /// stale data from showing in the tree.
    public private(set) var generation: UInt64 = 0

    // MARK: - Initialization

    public init(root: DocumentNode) {
        self.rootID = root.id
        self.nodesById = [root.id: root]
    }

    /// Bulk initializer for constructing a NodeIndex from a pre-built node dictionary.
    /// Used by `StructuralIndex.buildNodeIndex()` after Phase 1 parsing.
    public init(rootID: NodeID, allNodes: [NodeID: DocumentNode]) {
        self.rootID = rootID
        self.nodesById = allNodes
    }

    // MARK: - Query API

    /// The root node.
    public var root: DocumentNode? { nodesById[rootID] }

    /// O(1) lookup by ID.
    public func node(for id: NodeID) -> DocumentNode? {
        nodesById[id]
    }

    /// Direct children of the given node, in document order.
    public func children(of id: NodeID) -> [DocumentNode] {
        guard let node = nodesById[id] else { return [] }
        return node.childIDs.compactMap { nodesById[$0] }
    }

    /// Parent of the given node, or nil for the root.
    public func parent(of id: NodeID) -> DocumentNode? {
        guard let node = nodesById[id], let pid = node.parentID else { return nil }
        return nodesById[pid]
    }

    /// Ordered list of node IDs from root down to (and including) the given node.
    public func path(to id: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var current: NodeID? = id
        while let cid = current {
            result.append(cid)
            current = nodesById[cid]?.parentID
        }
        return result.reversed()
    }

    /// Human-readable path string, e.g. `"root.items[42].name"`.
    /// Array children are rendered with bracket notation using their `key` as the index.
    public func pathString(to id: NodeID) -> String {
        let ids = path(to: id)
        var result = "root"

        for nodeID in ids.dropFirst() {
            guard let node = nodesById[nodeID], let key = node.key else { continue }
            let parentType = node.parentID.flatMap { nodesById[$0] }?.type
            if parentType == .array {
                result += "[\(key)]"
            } else {
                result += ".\(key)"
            }
        }

        return result
    }

    // MARK: - Search

    /// All nodes matching the predicate. O(n).
    public func nodesMatching(predicate: (DocumentNode) -> Bool) -> [DocumentNode] {
        nodesById.values.filter(predicate)
    }

    /// All nodes at exactly the given depth. O(n).
    public func nodesAtDepth(_ depth: Int) -> [DocumentNode] {
        nodesById.values.filter { Int($0.depth) == depth }
    }

    // MARK: - Mutation (COW — callers receive a new index)

    /// Insert a node without touching parent references. Use `insertChild(_:in:at:)` for tree insertions.
    public mutating func insert(_ node: DocumentNode) {
        nodesById[node.id] = node
        generation &+= 1
    }

    /// Apply a transform to the node with the given ID. No-op if the ID is unknown.
    public mutating func updateNode(_ id: NodeID, transform: (inout DocumentNode) -> Void) {
        guard var node = nodesById[id] else { return }
        transform(&node)
        nodesById[id] = node
        generation &+= 1
    }

    /// Insert a child into the tree at the given position and register it in the parent's childIDs.
    public mutating func insertChild(_ node: DocumentNode, in parentID: NodeID, at index: Int) {
        nodesById[node.id] = node
        guard var parent = nodesById[parentID] else { return }
        let safeIndex = max(0, min(index, parent.childIDs.count))
        parent.childIDs.insert(node.id, at: safeIndex)
        nodesById[parentID] = parent
        generation &+= 1
    }

    /// Remove a node and its entire subtree. Also removes the node from its parent's childIDs.
    public mutating func removeNode(_ id: NodeID) {
        guard let node = nodesById[id] else { return }
        if let pid = node.parentID, var parent = nodesById[pid] {
            parent.childIDs.removeAll { $0 == id }
            nodesById[pid] = parent
        }
        removeSubtree(id)
        generation &+= 1
    }

    /// Bulk-apply a snapshot from an `EditTransaction`.
    ///
    /// - `updates`   — nodes to add or overwrite.
    /// - `deletions` — node IDs to remove (entries only; does not recurse).
    ///
    /// The caller is responsible for ensuring parent `childIDs` are consistent
    /// (i.e. the snapshot should include updated parent nodes where needed).
    public mutating func applySnapshot(_ updates: [NodeID: DocumentNode],
                                        deletions: Set<NodeID> = []) {
        for (id, node) in updates { nodesById[id] = node }
        for id in deletions { nodesById.removeValue(forKey: id) }
        generation &+= 1
    }

    // MARK: - Tabular detection

    /// Returns `true` when the root is an array of uniform objects suitable
    /// for spreadsheet-style table display.
    ///
    /// **Criteria (sampled):**
    /// - Root type is `.array`.
    /// - Every sampled child is `.object`.
    /// - All sampled objects share the same ordered key list.
    ///
    /// Only the first `sampleSize` rows are checked so this stays fast even on
    /// 100 k-row CSV files.
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
    ///
    /// Returns an empty array when `isTabular()` is `false`.
    public var tabularColumns: [String] {
        guard let root = self.root, root.type == .array,
              let firstRow = children(of: root.id).first else { return [] }
        return children(of: firstRow.id).compactMap { $0.key }
    }

    private mutating func removeSubtree(_ id: NodeID) {
        guard let node = nodesById[id] else { return }
        for childID in node.childIDs {
            removeSubtree(childID)
        }
        nodesById.removeValue(forKey: id)
    }
}
