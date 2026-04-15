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

    // MARK: - StructuralIndex search (large / lazily-loaded files)

    /// Search `si` for `query` without materialising a `NodeIndex`.
    ///
    /// Iterates `StructuralIndex.entries` in document order, resolving keys and
    /// scalar values from `file` bytes on demand (simdjson path) or from the
    /// pre-parsed fields on `IndexEntry` (Foundation path).
    ///
    /// Runs synchronously — call from a background `Task` for large documents.
    public static func search(query: String,
                               in si: StructuralIndex,
                               file: MappedFile?) -> [SearchMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let q = trimmed.lowercased()

        var results: [SearchMatch] = []
        struct MatchKey: Hashable {
            let id: NodeID
            let field: SearchMatch.Field
        }
        var seen = Set<MatchKey>()

        for entry in si.entries {
            switch entry.nodeType {

            case .keyValue:
                // Key match: use eagerly-parsed key when available (Foundation path),
                // else fall back to parsing the raw bytes from the mmap'd file.
                let key = entry.key ?? parseKeyBytes(entry: entry, from: file)
                if let key, key.lowercased().contains(q) {
                    let mk = MatchKey(id: entry.id, field: .key)
                    if seen.insert(mk).inserted {
                        results.append(SearchMatch(rowNodeID: entry.id,
                                                   field: .key,
                                                   matchedText: key))
                    }
                }

            case .scalar:
                // Value match: use eagerly-parsed value when available, else bytes.
                let sv: ScalarValue?
                if let pv = entry.parsedValue {
                    sv = pv
                } else {
                    sv = parseScalarBytes(entry: entry, from: file)
                }
                if let sv {
                    let text = sv.searchableText
                    if text.lowercased().contains(q) {
                        // Scalars inside a keyValue row are rendered inline — the
                        // keyValue parent is the display row to select/scroll to.
                        let rowID: NodeID
                        if let pid = entry.parentID,
                           si.entry(for: pid)?.nodeType == .keyValue {
                            rowID = pid
                        } else {
                            rowID = entry.id
                        }
                        let mk = MatchKey(id: rowID, field: .value)
                        if seen.insert(mk).inserted {
                            results.append(SearchMatch(rowNodeID: rowID,
                                                       field: .value,
                                                       matchedText: text))
                        }
                    }
                }

            case .object, .array:
                break   // containers have no searchable content
            }
        }

        return results
    }

    // MARK: - Byte-level parse helpers

    private static func parseKeyBytes(entry: IndexEntry, from file: MappedFile?) -> String? {
        guard let file, entry.byteLength > 0,
              let raw = try? file.data(offset: entry.byteOffset, length: entry.byteLength),
              let str = try? JSONSerialization.jsonObject(with: raw,
                                                          options: .allowFragments) as? String
        else { return nil }
        return str
    }

    private static func parseScalarBytes(entry: IndexEntry, from file: MappedFile?) -> ScalarValue? {
        guard entry.nodeType == .scalar, let file, entry.byteLength > 0,
              let raw = try? file.data(offset: entry.byteOffset, length: entry.byteLength),
              let any = try? JSONSerialization.jsonObject(with: raw, options: .allowFragments)
        else { return nil }
        return scalarFromAny(any)
    }

    private static func scalarFromAny(_ any: Any) -> ScalarValue {
        if let b = any as? Bool { return .boolean(b) }
        if let n = any as? NSNumber,
           CFGetTypeID(n as CFTypeRef) != CFBooleanGetTypeID() {
            if n.doubleValue.truncatingRemainder(dividingBy: 1) == 0,
               n.doubleValue >= Double(Int64.min),
               n.doubleValue <= Double(Int64.max) {
                return .integer(n.int64Value)
            }
            return .float(n.doubleValue)
        }
        if let s = any as? String { return .string(s) }
        if any is NSNull { return .null }
        return .string(String(describing: any))
    }
}
