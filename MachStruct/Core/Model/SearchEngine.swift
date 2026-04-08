import Foundation

// MARK: - SearchMatch

/// A single search hit resolved to the tree row that should be highlighted.
///
/// The `rowNodeID` is always the ID of a node that actually appears as a row
/// in the tree — i.e. never a scalar node that is rendered inline inside its
/// parent `keyValue` row.  See `SearchEngine.displayRowNodeID(for:in:)`.
public struct SearchMatch: Sendable {

    /// The node ID whose tree row should be highlighted and navigated to.
    public let rowNodeID: NodeID

    /// Which field of the row was matched.
    public enum Field: Sendable, Equatable, Hashable {
        case key    // the key label on the left of the row
        case value  // the value/summary on the right of the row
    }
    public let field: Field

    /// The raw (unquoted) text that matched the query.
    public let matchedText: String
}

// MARK: - SearchEngine

/// Stateless full-text search over a `NodeIndex`.
///
/// Searches both keys and scalar values, case-insensitively.
/// Results are returned in document order (DFS pre-order traversal).
/// Each distinct `(rowNodeID, field)` pair appears at most once.
///
/// Usage:
/// ```swift
/// let matches = SearchEngine.search(query: "alice", in: index)
/// ```
public enum SearchEngine {

    // MARK: - Public API

    /// Search `index` for `query`.  Returns `[]` when `query` is empty or
    /// contains only whitespace.  Runs synchronously — call from a background
    /// `Task` for large documents.
    public static func search(query: String, in index: NodeIndex) -> [SearchMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let q = trimmed.lowercased()
        var results: [SearchMatch] = []

        // Track (rowNodeID, field) pairs to avoid duplicate entries when e.g.
        // a keyValue node's key and its scalar child's value both match.
        struct MatchKey: Hashable {
            let id: NodeID
            let field: SearchMatch.Field
        }
        var seen = Set<MatchKey>()

        // Traverse in DFS pre-order so results are sorted top-to-bottom.
        traverse(index) { node in

            // ── Key match ───────────────────────────────────────────────────
            if let key = node.key, key.lowercased().contains(q) {
                let rowID = displayRowNodeID(for: node, in: index)
                let mk = MatchKey(id: rowID, field: .key)
                if seen.insert(mk).inserted {
                    results.append(SearchMatch(rowNodeID: rowID,
                                               field: .key,
                                               matchedText: key))
                }
            }

            // ── Scalar value match ───────────────────────────────────────────
            if case .scalar(let sv) = node.value {
                let text = sv.searchableText
                if text.lowercased().contains(q) {
                    let rowID = displayRowNodeID(for: node, in: index)
                    let mk = MatchKey(id: rowID, field: .value)
                    if seen.insert(mk).inserted {
                        results.append(SearchMatch(rowNodeID: rowID,
                                                   field: .value,
                                                   matchedText: text))
                    }
                }
            }
        }

        return results
    }

    // MARK: - Private helpers

    /// DFS pre-order traversal over every node in the index.
    private static func traverse(_ index: NodeIndex, body: (DocumentNode) -> Void) {
        var stack: [NodeID] = [index.rootID]
        while !stack.isEmpty {
            let id = stack.removeLast()
            guard let node = index.node(for: id) else { continue }
            body(node)
            // Push children in reverse order so the first child is processed first.
            for childID in node.childIDs.reversed() {
                stack.append(childID)
            }
        }
    }

    /// Resolve `node` to the ID of the tree row that actually displays it.
    ///
    /// In the tree, scalar children of `keyValue` nodes are rendered inline
    /// inside the `keyValue` row — they never appear as independent rows.
    /// For such scalars, the `keyValue` parent is the display row.
    /// All other node types appear directly as rows.
    private static func displayRowNodeID(for node: DocumentNode,
                                          in index: NodeIndex) -> NodeID {
        if node.type == .scalar,
           let parentID = node.parentID,
           let parent = index.node(for: parentID),
           parent.type == .keyValue {
            return parentID   // scalar is inline — highlight the keyValue row
        }
        return node.id
    }
}
