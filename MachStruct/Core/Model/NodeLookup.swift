import Foundation

// MARK: - NodeLookup

/// Read access to a document's nodes by ID, for code that only follows
/// `childIDs` down from the root: a `NodeIndex`, or a large file's index with
/// its source behind it (`DocumentOverlay`).
public protocol NodeLookup: Sendable {
    var rootID: NodeID { get }
    func node(for id: NodeID) -> DocumentNode?
}

extension NodeIndex: NodeLookup {}

// MARK: - DocumentOverlay

/// A large document as edited: each node from `index` when it holds it, and
/// otherwise built from `source` on each lookup, without keeping it.
///
/// Nodes built here have no `parentID` and a `depth` of 0: they are for
/// reading values and walking down, not for placing in the tree.
public struct DocumentOverlay: NodeLookup {
    public let index: NodeIndex
    public let source: (any DocumentSource)?

    public init(index: NodeIndex, source: (any DocumentSource)?) {
        self.index = index
        self.source = source
    }

    public var rootID: NodeID { index.rootID }

    public func node(for id: NodeID) -> DocumentNode? {
        index.node(for: id) ?? source?.node(for: id, parent: nil, internKeys: false)
    }
}

// MARK: - Loading for an edit

extension DocumentSource {

    /// `ids` and their ancestors, and with `subtrees` everything below them
    /// too, as `index` has them or as parsed: what an edit that touches nodes
    /// never expanded needs loaded.
    ///
    /// The ancestors matter for saving, which copies the original bytes of any
    /// container the index lacks and so would drop the edits inside it; the
    /// subtrees, for an edit that removes nodes and must be able to undo it.
    ///
    /// Nodes `index` holds are included: one may be evicted before the result
    /// is used. Load with `NodeIndex.load(_:)`, which adds only the missing.
    public func nodesToLoad(for ids: [NodeID], subtrees: Bool,
                            in index: NodeIndex) -> [NodeID: DocumentNode] {
        var nodes = [NodeID: DocumentNode]()
        func node(_ id: NodeID, parent: DocumentNode?) -> DocumentNode? {
            if let node = nodes[id] { return node }
            guard let node = index.node(for: id)
                    ?? self.node(for: id, parent: parent, internKeys: true) else { return nil }
            nodes[id] = node
            return node
        }

        for id in ids {
            // A node the user inserted isn't in the source; its ancestors,
            // like every edit's, are in the index already.
            var parent: DocumentNode?
            for ancestorID in path(to: id) {
                parent = node(ancestorID, parent: parent)
                if parent == nil { break }
            }
            guard subtrees, let top = parent ?? index.node(for: id) else { continue }
            var stack = [top]
            while let current = stack.popLast() {
                for childID in current.childIDs.reversed() {
                    if let child = node(childID, parent: current) { stack.append(child) }
                }
            }
        }
        return nodes
    }

    /// `index` with `nodesToLoad(for:subtrees:in:)` loaded.
    public func loading(_ ids: [NodeID], subtrees: Bool, into index: NodeIndex) -> NodeIndex {
        var result = index
        result.load(nodesToLoad(for: ids, subtrees: subtrees, in: index))
        return result
    }
}

extension NodeIndex {

    /// Adds those of `nodes` this index lacks. Loading is not an edit: the
    /// nodes are as parsed, and any the index holds are kept as they are.
    public mutating func load(_ nodes: [NodeID: DocumentNode]) {
        applySnapshot(nodes.filter { node(for: $0.key) == nil })
    }
}
