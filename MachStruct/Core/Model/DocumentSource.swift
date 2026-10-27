import Foundation

// MARK: - DocumentSource

/// Where the nodes of a large document come from when they are not in its
/// `NodeIndex` (ADR-002).
///
/// A large file's `NodeIndex` holds only what is shown and what has been
/// edited. Everything else is built on demand from a source: the file's own
/// bytes for JSON (`JSONSource`), or a `StructuralIndex` for formats that are
/// indexed node by node. A source node's ID never changes, so a node rebuilt
/// after eviction is the same node.
public protocol DocumentSource: Sendable {

    /// The document's root node.
    var rootID: NodeID { get }

    /// Values plus object members in the document as parsed.
    var nodeCount: Int { get }

    /// The node `id` as parsed, or `nil` if it is not a node of this source.
    ///
    /// `parent` is the node's parent, which gives it its `parentID` and
    /// `depth`; without it they are `nil` and 0. Keys are interned when
    /// `internKeys` is true, which callers building many short-lived nodes
    /// turn off so the intern table doesn't grow with the document.
    func node(for id: NodeID, parent: DocumentNode?, internKeys: Bool) -> DocumentNode?

    /// The IDs from the root down to `id`, or `[]` when `id` isn't a node of
    /// this source.
    func path(to id: NodeID) -> [NodeID]

    /// True when the root is an array of objects with the same keys, sampled
    /// from its first items.
    func looksTabular() -> Bool

    /// Search the subtrees at `ids` — consecutive siblings no index holds —
    /// for `query` (lowercased), reporting each match in document order as
    /// the row showing it, the field matched and the matched text. Return
    /// `false` from `match` to stop.
    ///
    /// Returns how many of `ids`, from the first, it searched. The caller
    /// builds the nodes of the next one itself, so a source can decline any
    /// subtree it can't search from its bytes.
    func searchUnloaded(_ ids: ArraySlice<NodeID>, query: String,
                        _ match: (NodeID, SearchMatch.Field, String) -> Bool) -> Int
}

extension DocumentSource {

    public func searchUnloaded(_ ids: ArraySlice<NodeID>, query: String,
                               _ match: (NodeID, SearchMatch.Field, String) -> Bool) -> Int {
        0
    }

    public func node(for id: NodeID, parent: DocumentNode?) -> DocumentNode? {
        node(for: id, parent: parent, internKeys: true)
    }

    /// The parent of `id`, found from the root.
    public func parentID(of id: NodeID) -> NodeID? {
        let path = path(to: id)
        return path.count >= 2 ? path[path.count - 2] : nil
    }

    /// Visits every node of the document in document order (depth first),
    /// taking each from `index` when it is there and building it from the
    /// source otherwise. `visit` gets the node and its parent; return `false`
    /// to skip the node's children.
    ///
    /// Nodes in `index` reflect the user's edits; a subtree missing from it is
    /// unedited, so the source describes it correctly.
    ///
    /// `unloaded`, if given, is offered each run of consecutive siblings
    /// missing from `index` (with their parent) before they are built. It
    /// returns how many of them, from the first, it has handled; those
    /// subtrees are then not built or visited.
    public func traverse(overlaying index: NodeIndex,
                         from start: NodeID? = nil,
                         internKeys: Bool = false,
                         unloaded: ((ArraySlice<NodeID>, DocumentNode) -> Int)? = nil,
                         _ visit: (DocumentNode, DocumentNode?) -> Bool) {
        let startID = start ?? index.rootID
        guard let first = index.node(for: startID)
                ?? node(for: startID, parent: nil, internKeys: internKeys) else { return }
        // One frame per level: a node and its next child to visit. Building
        // children only as they are reached keeps memory to the depth of the
        // tree, not the width of its widest container.
        var frames: [(node: DocumentNode, next: Int)] = []
        if visit(first, nil), !first.childIDs.isEmpty { frames.append((first, 0)) }
        var visited = 0
        while let top = frames.last {
            guard top.next < top.node.childIDs.count else {
                frames.removeLast()
                continue
            }
            let childIDs = top.node.childIDs
            let childID = childIDs[top.next]
            visited += 1
            if visited & 0x3FFF == 0, Task.isCancelled { return }
            let loaded = index.node(for: childID)
            if loaded == nil, let unloaded {
                var end = top.next + 1
                while end < childIDs.count, end - top.next < 4_096,
                      index.node(for: childIDs[end]) == nil { end += 1 }
                let handled = unloaded(childIDs[top.next ..< end], top.node)
                if handled > 0 {
                    frames[frames.count - 1].next += handled
                    visited += handled - 1
                    continue
                }
            }
            frames[frames.count - 1].next += 1
            guard let child = loaded
                    ?? node(for: childID, parent: top.node, internKeys: internKeys) else { continue }
            if visit(child, top.node), !child.childIDs.isEmpty { frames.append((child, 0)) }
        }
    }

    /// The whole document as a `NodeIndex`, with the nodes of `current`
    /// (the user's edits) in place of the parsed ones.
    public func completeNodeIndex(overlaying current: NodeIndex) -> NodeIndex {
        var storage = ContiguousArray<DocumentNode>()
        var positions = [NodeID: Int]()
        storage.reserveCapacity(nodeCount)
        positions.reserveCapacity(nodeCount)
        traverse(overlaying: current, internKeys: true) { node, _ in
            positions[node.id] = storage.count
            storage.append(node)
            return true
        }
        return NodeIndex(rootID: current.rootID, storage: storage, positions: positions)
    }
}
