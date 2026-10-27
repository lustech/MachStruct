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

/// Stateless full-text search over either a `NodeIndex` or a `StructuralIndex`.
///
/// Searches both keys and scalar values, case-insensitively.
/// Results are returned in document order (DFS pre-order for `NodeIndex`,
/// flat entry order for `StructuralIndex` — which is also document order).
/// Each distinct `(rowNodeID, field)` pair appears at most once.
///
/// Usage:
/// ```swift
/// // Fully-materialised path (small files):
/// let matches = SearchEngine.search(query: "alice", in: nodeIndex)
///
/// // Lazy path (large files — no NodeIndex materialisation required):
/// let matches = SearchEngine.search(query: "alice", in: structuralIndex, file: mappedFile)
/// ```
public enum SearchEngine {

    // MARK: - NodeIndex search (small / fully-materialised files)

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

    // MARK: - Large files

    /// Search a large document as it is now, edits included.
    ///
    /// Walks the tree in document order. A node that `index` holds is read
    /// from there — its key, value and current children — since it may have
    /// been edited; any other node is built from `source`. That is sound
    /// because edited nodes and their ancestors are never evicted, and a
    /// deleted node is no longer among its parent's children, so it is never
    /// reached (#63).
    public static func search(query: String,
                              in index: NodeIndex,
                              source: any DocumentSource) -> [SearchMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let q = trimmed.lowercased()

        var results: [SearchMatch] = []
        // A row is listed once even if both its key and its value match.
        struct MatchKey: Hashable {
            let id: NodeID
            let field: SearchMatch.Field
        }
        var seen = Set<MatchKey>()

        // A JSON subtree that isn't loaded is unedited: scan its bytes, which
        // skips what can't match without building any nodes.
        let json = source as? JSONSource
        let needle = Array(q.utf8)
        let scanBytes: ((NodeID, DocumentNode) -> Bool)? = json.map { json in
            { id, _ in
                var scanned = 0
                json.searchCandidates(in: id, needle: needle) { row, field, token in
                    let text: String?
                    if field == .key {
                        text = JSONParser.decodeStringToken(token)
                    } else {
                        text = JSONParser.decodeScalarBytes(token)?.searchableText
                    }
                    if let text, text.lowercased().contains(q),
                       seen.insert(MatchKey(id: row, field: field)).inserted {
                        results.append(SearchMatch(rowNodeID: row, field: field, matchedText: text))
                    }
                    scanned += 1
                    return scanned & 0xFFF != 0 || !Task.isCancelled
                }
                return true
            }
        }

        source.traverse(overlaying: index, unloaded: scanBytes) { node, parent in
            switch node.type {
            case .keyValue:
                if let key = node.key, key.lowercased().contains(q),
                   seen.insert(MatchKey(id: node.id, field: .key)).inserted {
                    results.append(SearchMatch(rowNodeID: node.id, field: .key, matchedText: key))
                }
            case .scalar:
                if case .scalar(let sv) = node.value {
                    let text = sv.searchableText
                    // A scalar under a keyValue is shown on its key's row.
                    let rowID = parent?.type == .keyValue ? parent!.id : node.id
                    if text.lowercased().contains(q),
                       seen.insert(MatchKey(id: rowID, field: .value)).inserted {
                        results.append(SearchMatch(rowNodeID: rowID, field: .value,
                                                   matchedText: text))
                    }
                }
            case .object, .array:
                break   // containers have no searchable content
            }
            return true
        }
        return results
    }
}
