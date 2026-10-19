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

    public init(index: NodeIndex, mappedFile: MappedFile? = nil) {
        self.index = index
        self.mappedFile = mappedFile
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

        // A container whose children were never materialised (lazy index) has
        // no subtree to walk. Its original bytes are already valid JSON, so
        // copy them through — exact, and avoids emitting an empty container
        // for every unexpanded node of a large file.
        //
        // The test must be whether the children *resolve*, not whether
        // `childIDs` is populated: `buildShallowNodeIndex` fills `childIDs`
        // from the structural index without materialising the nodes they
        // point at, so a node can claim children the index cannot produce.
        let children = index.children(of: node.id)
        if children.count < expectedChildCount(of: node), let raw = rawSource(of: node) {
            out += raw
            return
        }

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
                if let valueChild = index.children(of: child.id).first {
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

    /// How many children the document says this container has.
    ///
    /// `.container(childCount:)` is recorded at parse time and is accurate even
    /// when none of those children have been materialised.
    private func expectedChildCount(of node: DocumentNode) -> Int {
        guard case .container(let expected) = node.value else { return 0 }
        return expected
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
