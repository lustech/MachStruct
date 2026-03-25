import Foundation

// MARK: - EditTransaction

/// A reversible, self-contained edit operation on a `NodeIndex`.
///
/// Every user action that mutates the document is captured as an
/// `EditTransaction` so it can be undone and redone without replaying events.
///
/// **Snapshot strategy:**
/// - `beforeSnapshot` — the subset of nodes *as they were* before the edit.
/// - `afterSnapshot`  — the subset of nodes *as they are* after the edit.
/// - `deletedIDs`     — IDs of nodes that existed before but no longer do.
/// - `insertedIDs`    — IDs of nodes that did not exist before but do now.
///
/// Applying the transaction means writing `afterSnapshot` into the index and
/// removing `deletedIDs`.  Reverting means writing `beforeSnapshot` and removing
/// `insertedIDs`.
///
/// Only nodes that actually changed are stored in the snapshots, so for a
/// single-value edit only one or two nodes are captured regardless of tree size.
public struct EditTransaction: Sendable {

    // MARK: - Properties

    public let id: UUID
    public let timestamp: Date
    /// Text that appears in the Edit menu — e.g. "Change Value of 'name'".
    public let description: String

    public let affectedNodeIDs: Set<NodeID>
    public let beforeSnapshot: [NodeID: DocumentNode]
    public let afterSnapshot: [NodeID: DocumentNode]

    /// Nodes removed by this transaction (e.g. a deleted subtree).
    public let deletedIDs: Set<NodeID>
    /// Nodes added by this transaction (e.g. a newly inserted pair).
    public let insertedIDs: Set<NodeID>

    // MARK: - Init

    public init(description: String,
                affectedNodeIDs: Set<NodeID>,
                beforeSnapshot: [NodeID: DocumentNode],
                afterSnapshot: [NodeID: DocumentNode],
                deletedIDs: Set<NodeID> = [],
                insertedIDs: Set<NodeID> = []) {
        self.id              = UUID()
        self.timestamp       = Date()
        self.description     = description
        self.affectedNodeIDs = affectedNodeIDs
        self.beforeSnapshot  = beforeSnapshot
        self.afterSnapshot   = afterSnapshot
        self.deletedIDs      = deletedIDs
        self.insertedIDs     = insertedIDs
    }

    // MARK: - Apply / Revert

    /// Returns a new index with this transaction's changes applied (forward).
    public func applying(to index: NodeIndex) -> NodeIndex {
        var idx = index
        idx.applySnapshot(afterSnapshot, deletions: deletedIDs)
        return idx
    }

    /// Returns a new index with this transaction's changes reverted (undo).
    public func reverting(from index: NodeIndex) -> NodeIndex {
        var idx = index
        idx.applySnapshot(beforeSnapshot, deletions: insertedIDs)
        return idx
    }

    /// Returns a transaction that, when applied, produces the *before* state.
    /// Used by `StructDocument.commitEdit` to register symmetric undo/redo.
    public var reversed: EditTransaction {
        EditTransaction(
            description: description,
            affectedNodeIDs: affectedNodeIDs,
            beforeSnapshot: afterSnapshot,   // swap
            afterSnapshot: beforeSnapshot,   // swap
            deletedIDs: insertedIDs,         // swap
            insertedIDs: deletedIDs          // swap
        )
    }
}

// MARK: - Factory Methods

public extension EditTransaction {

    // MARK: Change scalar value

    /// Creates a transaction that changes the `.value` of a scalar node.
    static func changeValue(of nodeID: NodeID,
                             to newValue: NodeValue,
                             description: String,
                             in index: NodeIndex) -> EditTransaction? {
        guard var node = index.node(for: nodeID) else { return nil }
        let before = node
        node.value = newValue
        return EditTransaction(
            description: description,
            affectedNodeIDs: [nodeID],
            beforeSnapshot: [nodeID: before],
            afterSnapshot:  [nodeID: node]
        )
    }

    // MARK: Rename key

    /// Creates a transaction that renames the `.key` of a keyValue node.
    static func renameKey(of nodeID: NodeID,
                           to newKey: String,
                           in index: NodeIndex) -> EditTransaction? {
        guard var node = index.node(for: nodeID), node.type == .keyValue else { return nil }
        let before = node
        node.key   = newKey
        let description = "Rename Key to '\(newKey)'"
        return EditTransaction(
            description: description,
            affectedNodeIDs: [nodeID],
            beforeSnapshot: [nodeID: before],
            afterSnapshot:  [nodeID: node]
        )
    }

    // MARK: Insert key-value pair

    /// Creates a transaction that appends a new key-value/scalar pair into a
    /// container node.  Inserts at the end.
    static func insertKeyValue(key: String,
                                value: ScalarValue = .string(""),
                                into parentID: NodeID,
                                in index: NodeIndex) -> EditTransaction? {
        guard let parent = index.node(for: parentID),
              parent.type == .object else { return nil }

        // Build the new nodes.
        let kvNode = DocumentNode(
            id: NodeID.generate(),
            type: .keyValue,
            depth: parent.depth + 1,
            parentID: parentID,
            key: key,
            value: .unparsed
        )
        let scalarNode = DocumentNode(
            id: NodeID.generate(),
            type: .scalar,
            depth: parent.depth + 2,
            parentID: kvNode.id,
            value: .scalar(value)
        )
        var updatedKV = kvNode
        updatedKV.childIDs = [scalarNode.id]

        var updatedParent = parent
        updatedParent.childIDs.append(kvNode.id)

        return EditTransaction(
            description: "Add Key '\(key)'",
            affectedNodeIDs: [parentID, kvNode.id, scalarNode.id],
            beforeSnapshot: [parentID: parent],
            afterSnapshot:  [parentID: updatedParent,
                             kvNode.id: updatedKV,
                             scalarNode.id: scalarNode],
            insertedIDs: [kvNode.id, scalarNode.id]
        )
    }

    // MARK: Insert array item

    /// Appends a new scalar item to an array node.
    static func insertArrayItem(value: ScalarValue = .string(""),
                                 into parentID: NodeID,
                                 in index: NodeIndex) -> EditTransaction? {
        guard let parent = index.node(for: parentID),
              parent.type == .array else { return nil }

        let index_ = parent.childIDs.count
        let itemNode = DocumentNode(
            id: NodeID.generate(),
            type: .scalar,
            depth: parent.depth + 1,
            parentID: parentID,
            key: String(index_),
            value: .scalar(value)
        )
        var updatedParent = parent
        updatedParent.childIDs.append(itemNode.id)

        return EditTransaction(
            description: "Add Item [\(index_)]",
            affectedNodeIDs: [parentID, itemNode.id],
            beforeSnapshot: [parentID: parent],
            afterSnapshot:  [parentID: updatedParent, itemNode.id: itemNode],
            insertedIDs: [itemNode.id]
        )
    }

    // MARK: Remove node

    /// Creates a transaction that removes a node and its entire subtree.
    /// Also updates the parent's childIDs.
    static func removeNode(_ nodeID: NodeID,
                            in index: NodeIndex) -> EditTransaction? {
        guard let node = index.node(for: nodeID) else { return nil }

        // Collect the full subtree.
        var subtree: [NodeID: DocumentNode] = [:]
        collectSubtree(nodeID, in: index, into: &subtree)

        // Capture parent before the removal.
        var parentSnapshot: [NodeID: DocumentNode] = [:]
        if let pid = node.parentID, let parent = index.node(for: pid) {
            parentSnapshot[pid] = parent
        }

        // Build updated parent with the child removed.
        var updatedParents: [NodeID: DocumentNode] = [:]
        if let pid = node.parentID, var parent = index.node(for: pid) {
            parent.childIDs.removeAll { $0 == nodeID }
            updatedParents[pid] = parent
        }

        let keyLabel = node.key.map { "'\($0)'" } ?? "node"
        return EditTransaction(
            description: "Delete \(keyLabel)",
            affectedNodeIDs: Set(subtree.keys).union(parentSnapshot.keys),
            beforeSnapshot: subtree.merging(parentSnapshot) { a, _ in a },
            afterSnapshot:  updatedParents,
            deletedIDs: Set(subtree.keys)
        )
    }

    // MARK: - Helpers

    private static func collectSubtree(_ id: NodeID,
                                        in index: NodeIndex,
                                        into result: inout [NodeID: DocumentNode]) {
        guard let node = index.node(for: id) else { return }
        result[id] = node
        for childID in node.childIDs {
            collectSubtree(childID, in: index, into: &result)
        }
    }
}
