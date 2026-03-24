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

    // MARK: - Initialization

    public init(root: DocumentNode) {
        self.rootID = root.id
        self.nodesById = [root.id: root]
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
    }

    /// Apply a transform to the node with the given ID. No-op if the ID is unknown.
    public mutating func updateNode(_ id: NodeID, transform: (inout DocumentNode) -> Void) {
        guard var node = nodesById[id] else { return }
        transform(&node)
        nodesById[id] = node
    }

    /// Insert a child into the tree at the given position and register it in the parent's childIDs.
    public mutating func insertChild(_ node: DocumentNode, in parentID: NodeID, at index: Int) {
        nodesById[node.id] = node
        guard var parent = nodesById[parentID] else { return }
        let safeIndex = max(0, min(index, parent.childIDs.count))
        parent.childIDs.insert(node.id, at: safeIndex)
        nodesById[parentID] = parent
    }

    /// Remove a node and its entire subtree. Also removes the node from its parent's childIDs.
    public mutating func removeNode(_ id: NodeID) {
        guard let node = nodesById[id] else { return }
        if let pid = node.parentID, var parent = nodesById[pid] {
            parent.childIDs.removeAll { $0 == id }
            nodesById[pid] = parent
        }
        removeSubtree(id)
    }

    private mutating func removeSubtree(_ id: NodeID) {
        guard let node = nodesById[id] else { return }
        for childID in node.childIDs {
            removeSubtree(childID)
        }
        nodesById.removeValue(forKey: id)
    }
}
