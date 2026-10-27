import Foundation

// MARK: - JSONDocumentSerializer

/// Serializes a `NodeIndex` to JSON `Data`.
///
/// Emits text directly from the node tree rather than building a Foundation
/// object and calling `JSONSerialization`. That round-trip lost three things a
/// structured-file viewer must not lose (issues #29, #31):
///
/// - **Key order.** `[String: Any]` is unordered, so saving reshuffled keys.
/// - **Duplicate keys.** A dictionary cannot hold them, so `{"k":1,"k":2}`
///   collapsed to one entry.
/// - **Number fidelity.** Foundation prints doubles at full precision, turning
///   `8.7` into `8.6999999999999993` and `1.0` into `1`.
///
/// The YAML serializer already emitted text directly and was correct on all
/// three; this now matches it.
///
/// **Unparsed nodes**: large files (≥ 5 MB) leave scalars `.unparsed` and
/// containers unmaterialised. Where a `MappedFile` is available their original
/// bytes are copied through verbatim, which is both exact and fast. Without a
/// mapped file an unparsed scalar serializes as `null`.
public struct JSONDocumentSerializer {

    private let index: NodeIndex
    private let mappedFile: MappedFile?
    /// Builds the nodes of a large file that `index` doesn't hold.
    private let source: (any DocumentSource)?

    public init(index: NodeIndex, mappedFile: MappedFile? = nil,
                source: (any DocumentSource)? = nil) {
        self.index = index
        self.mappedFile = mappedFile
        self.source = source
    }

    // MARK: - Public API

    /// Serialize the entire document to JSON bytes.
    ///
    /// A trailing newline is appended so files match the convention used by
    /// most editors.
    public func serialize(pretty: Bool = true) throws -> Data {
        guard let root = index.root else {
            throw JSONSerializerError.emptyDocument
        }
        var out = ""
        out.reserveCapacity(4096)
        emit(root, into: &out, depth: 0, pretty: pretty)
        out += "\n"
        return Data(out.utf8)
    }

    /// Serialize the subtree rooted at a specific node.
    ///
    /// Useful for copying a single node to the clipboard.
    public func serialize(nodeID: NodeID, pretty: Bool = true) throws -> Data {
        guard let node = index.node(for: nodeID) else {
            throw JSONSerializerError.nodeNotFound
        }
        // For keyValue nodes expose the value child directly.
        let target = (node.type == .keyValue)
            ? (index.children(of: node.id).first ?? node)
            : node
        var out = ""
        emit(target, into: &out, depth: 0, pretty: pretty)
        return Data(out.utf8)
    }

    // MARK: - Emission

    private func emit(_ node: DocumentNode, into out: inout String,
                      depth: Int, pretty: Bool) {
        switch node.type {
        case .object, .array:
            emitContainer(node, into: &out, depth: depth, pretty: pretty)

        case .keyValue:
            // Reached when serializing a detached keyValue subtree.
            if let valueChild = index.children(of: node.id).first {
                emit(valueChild, into: &out, depth: depth, pretty: pretty)
            } else {
                out += "null"
            }

        case .scalar:
            out += scalarLiteral(node)
        }
    }

    private func emitContainer(_ node: DocumentNode, into out: inout String,
                               depth: Int, pretty: Bool) {
        let isObject = (node.type == .object)
        let open = isObject ? "{" : "["
        let close = isObject ? "}" : "]"

        // A node built from the source is unedited, so its original bytes
        // are copied: exact, and fast for the unexpanded parts of a large
        // file. A node the index holds may be edited, so it is written out
        // child by child, building any child it lacks from the source. That
        // per-child step is what keeps a deletion deleted: comparing against
        // the parse-time child count and copying the original bytes brought
        // a deleted child back on save.
        //
        // Without a source, a container whose children don't all resolve has
        // never been expanded, and its original bytes are the best available.
        if source != nil {
            if index.node(for: node.id) == nil, let raw = rawSource(of: node) {
                out += raw
                return
            }
        } else if index.children(of: node.id).count < node.childIDs.count,
                  let raw = rawSource(of: node) {
            out += raw
            return
        }
        let children = node.childIDs.compactMap { resolve($0, parent: node) }

        guard !children.isEmpty else {
            out += open + close
            return
        }

        out += open
        let inner = depth + 1
        var first = true
        for child in children {
            if isObject {
                // Skip anything that is not a key/value pair; an object cannot
                // represent it.
                guard child.type == .keyValue, let key = resolvedKey(of: child) else { continue }
                if !first { out += "," }
                first = false
                if pretty { out += "\n" + indent(inner) }
                out += jsonString(key)
                out += pretty ? " : " : ":"
                if let valueID = child.childIDs.first,
                   let valueChild = resolve(valueID, parent: child) {
                    emit(valueChild, into: &out, depth: inner, pretty: pretty)
                } else {
                    out += "null"
                }
            } else {
                if !first { out += "," }
                first = false
                if pretty { out += "\n" + indent(inner) }
                emit(child, into: &out, depth: inner, pretty: pretty)
            }
        }

        if first {
            // Every child was skipped.
            out += close
            return
        }
        if pretty { out += "\n" + indent(depth) }
        out += close
    }

    // MARK: - Node helpers

    private func resolve(_ id: NodeID, parent: DocumentNode) -> DocumentNode? {
        index.node(for: id) ?? source?.node(for: id, parent: parent, internKeys: false)
    }

    /// The node's key, falling back to the source bytes when the lazy path
    /// left it unresolved.
    private func resolvedKey(of node: DocumentNode) -> String? {
        if let key = node.key { return key }
        guard let file = mappedFile, node.sourceRange.byteLength > 0,
              let bytes = try? file.slice(offset: node.sourceRange.byteOffset,
                                          length: node.sourceRange.byteLength)
        else { return nil }
        return JSONParser.decodeStringToken(bytes)
    }

    /// The node's original bytes, when they are available and valid to copy.
    private func rawSource(of node: DocumentNode) -> String? {
        guard let file = mappedFile, node.sourceRange.byteLength > 0,
              let data = try? file.data(offset: node.sourceRange.byteOffset,
                                        length: node.sourceRange.byteLength)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func scalarLiteral(_ node: DocumentNode) -> String {
        // Built from the source, so unedited: keep its spelling.
        if source != nil, index.node(for: node.id) == nil, let raw = rawSource(of: node) {
            return raw
        }
        switch node.value {
        case .scalar(let sv):
            return literal(for: sv)

        case .unparsed:
            // Copy the original token through so its spelling is preserved.
            return rawSource(of: node) ?? "null"

        case .container, .error:
            return "null"
        }
    }

    private func literal(for sv: ScalarValue) -> String {
        switch sv {
        case .string(let s):  return jsonString(s)
        case .integer(let i): return String(i)
        case .float(let f):   return jsonDouble(f)
        case .boolean(let b): return b ? "true" : "false"
        case .null:           return "null"
        }
    }

    // MARK: - Literal formatting

    /// Format a double the way the source most likely spelled it.
    ///
    /// `String(Double)` gives the shortest representation that round-trips, so
    /// `8.7` stays `8.7`. Whole values keep a decimal point so a float is not
    /// silently demoted to an integer. JSON has no NaN or Infinity, so those
    /// degrade to `null` rather than producing a document that will not parse.
    private func jsonDouble(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value.truncatingRemainder(dividingBy: 1) == 0,
           value.magnitude < 1e16 {
            return String(format: "%.1f", value)
        }
        return String(value)
    }

    private func jsonString(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf8.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"":      out += "\\\""
            case "\\":      out += "\\\\"
            case "\n":      out += "\\n"
            case "\r":      out += "\\r"
            case "\t":      out += "\\t"
            case "\u{08}":  out += "\\b"
            case "\u{0C}":  out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private func indent(_ depth: Int) -> String {
        String(repeating: "  ", count: depth)
    }
}

// MARK: - Errors

public enum JSONSerializerError: Error, Sendable {
    /// The NodeIndex contains no root node.
    case emptyDocument
    /// The requested NodeID was not found in the index.
    case nodeNotFound
}
