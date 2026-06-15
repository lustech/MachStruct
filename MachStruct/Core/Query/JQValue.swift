import Foundation

// MARK: - JQValue

/// The format-neutral value type the jq engine operates on.
///
/// jq is a JSON value language, so every document — JSON, YAML, CSV, XML — is
/// projected onto this small value model before queries run, and results are
/// projected back onto `DocumentNode`s for display.
///
/// Numbers keep their integer/float distinction (`.int` / `.double`) so that
/// round-tripping a document preserves how values are displayed; jq arithmetic
/// promotes to `.double` only when a fractional result is produced.
///
/// Object members are an *ordered* list of `(key, value)` pairs — jq preserves
/// insertion order, and so does the document tree, so equality is order
/// sensitive.
public enum JQValue: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JQValue])
    case object([(key: String, value: JQValue)])

    /// The jq type name, as returned by the `type` builtin.
    public var typeName: String {
        switch self {
        case .null:           return "null"
        case .bool:           return "boolean"
        case .int, .double:   return "number"
        case .string:         return "string"
        case .array:          return "array"
        case .object:         return "object"
        }
    }
}

// MARK: - Equatable

extension JQValue: Equatable {
    public static func == (lhs: JQValue, rhs: JQValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):                       return true
        case let (.bool(a), .bool(b)):             return a == b
        case let (.int(a), .int(b)):               return a == b
        case let (.double(a), .double(b)):         return a == b
        // Cross-kind numeric equality: `1` and `1.0` compare equal, matching jq.
        case let (.int(a), .double(b)):            return Double(a) == b
        case let (.double(a), .int(b)):            return a == Double(b)
        case let (.string(a), .string(b)):         return a == b
        case let (.array(a), .array(b)):           return a == b
        case let (.object(a), .object(b)):
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) where x.key != y.key || x.value != y.value {
                return false
            }
            return true
        default:                                   return false
        }
    }
}

// MARK: - JSON serialisation

extension JQValue {
    /// Serialise this value to a JSON string.  Object member order is preserved
    /// (unlike `JSONSerialization`, which sorts or randomises keys).  Used by the
    /// results pane for copy and export.
    public func jsonString(pretty: Bool = true) -> String {
        var out = ""
        write(into: &out, pretty: pretty, indent: 0)
        return out
    }

    private func write(into out: inout String, pretty: Bool, indent: Int) {
        let nl = pretty ? "\n" : ""
        let pad = pretty ? String(repeating: "  ", count: indent + 1) : ""
        let closePad = pretty ? String(repeating: "  ", count: indent) : ""
        let colon = pretty ? ": " : ":"

        switch self {
        case .null:          out += "null"
        case .bool(let b):   out += b ? "true" : "false"
        case .int(let i):    out += String(i)
        case .double(let d): out += String(d)
        case .string(let s): out += Self.encode(s)

        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[" + nl
            for (i, item) in items.enumerated() {
                out += pad
                item.write(into: &out, pretty: pretty, indent: indent + 1)
                if i < items.count - 1 { out += "," }
                out += nl
            }
            out += closePad + "]"

        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{" + nl
            for (i, member) in members.enumerated() {
                out += pad + Self.encode(member.key) + colon
                member.value.write(into: &out, pretty: pretty, indent: indent + 1)
                if i < members.count - 1 { out += "," }
                out += nl
            }
            out += closePad + "}"
        }
    }

    /// JSON-encode a string (quotes + minimal escapes).
    private static func encode(_ s: String) -> String {
        var r = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\t": r += "\\t"
            case "\r": r += "\\r"
            default:
                if ch.value < 0x20 {
                    r += String(format: "\\u%04x", ch.value)
                } else {
                    r.unicodeScalars.append(ch)
                }
            }
        }
        r += "\""
        return r
    }
}

// MARK: - ScalarValue bridge

extension JQValue {
    /// Project a fully-parsed leaf value onto a `JQValue`.
    init(scalar: ScalarValue) {
        switch scalar {
        case .string(let s):  self = .string(s)
        case .integer(let i): self = .int(i)
        case .float(let d):   self = .double(d)
        case .boolean(let b): self = .bool(b)
        case .null:           self = .null
        }
    }

    /// The leaf `ScalarValue` for a scalar `JQValue`, or `nil` for containers.
    var scalarValue: ScalarValue? {
        switch self {
        case .null:           return .null
        case .bool(let b):    return .boolean(b)
        case .int(let i):     return .integer(i)
        case .double(let d):  return .float(d)
        case .string(let s):  return .string(s)
        case .array, .object: return nil
        }
    }
}

// MARK: - DocumentNode → JQValue

extension JQValue {
    /// Project the document subtree rooted at `id` onto a `JQValue`.
    ///
    /// Reads already-materialised values from the `NodeIndex`.  A scalar that
    /// has not been materialised (`.unparsed`) projects to `.null` rather than
    /// failing — the lazy-materialisation path in `QueryEngine` is responsible
    /// for parsing values before querying large files.
    public init(node id: NodeID, in index: NodeIndex) {
        guard let node = index.node(for: id) else { self = .null; return }
        switch node.type {
        case .scalar:
            if case .scalar(let sv) = node.value {
                self = JQValue(scalar: sv)
            } else {
                self = .null
            }

        case .keyValue:
            // A key-value pair unwraps to its single value child.
            if let childID = node.childIDs.first {
                self = JQValue(node: childID, in: index)
            } else {
                self = .null
            }

        case .array:
            self = .array(node.childIDs.map { JQValue(node: $0, in: index) })

        case .object:
            var members: [(key: String, value: JQValue)] = []
            members.reserveCapacity(node.childIDs.count)
            for kvID in node.childIDs {
                guard let kv = index.node(for: kvID) else { continue }
                let key = kv.key ?? ""
                members.append((key, JQValue(node: kvID, in: index)))
            }
            self = .object(members)
        }
    }
}

// MARK: - JQValue → DocumentNode

extension JQValue {
    /// Materialise this value as a fresh `DocumentNode` subtree.
    ///
    /// Returns the new root node's ID and a dictionary of every created node,
    /// suitable for constructing a `NodeIndex` (results pane) or for an
    /// `EditTransaction` snapshot.  Mirrors the node shape produced by
    /// `EditTransaction.buildSubtree` so results render identically to documents.
    public func toDocumentNodes(parentID: NodeID?,
                                depth: UInt16,
                                key: String?) -> (root: NodeID, nodes: [NodeID: DocumentNode]) {
        var nodes: [NodeID: DocumentNode] = [:]
        let root = build(parentID: parentID, depth: depth, key: key, into: &nodes)
        return (root, nodes)
    }

    private func build(parentID: NodeID?,
                       depth: UInt16,
                       key: String?,
                       into nodes: inout [NodeID: DocumentNode]) -> NodeID {
        switch self {
        case .array(let items):
            let nodeID = NodeID.generate()
            var childIDs: [NodeID] = []
            for (i, item) in items.enumerated() {
                let childID = item.build(parentID: nodeID, depth: depth + 1,
                                         key: String(i), into: &nodes)
                childIDs.append(childID)
            }
            nodes[nodeID] = DocumentNode(id: nodeID, type: .array, depth: depth,
                                         parentID: parentID, childIDs: childIDs, key: key,
                                         value: .container(childCount: childIDs.count))
            return nodeID

        case .object(let members):
            let nodeID = NodeID.generate()
            var childIDs: [NodeID] = []
            for member in members {
                let kvID = NodeID.generate()
                let valueID = member.value.build(parentID: kvID, depth: depth + 2,
                                                 key: nil, into: &nodes)
                nodes[kvID] = DocumentNode(id: kvID, type: .keyValue, depth: depth + 1,
                                           parentID: nodeID, childIDs: [valueID],
                                           key: member.key, value: .unparsed)
                childIDs.append(kvID)
            }
            nodes[nodeID] = DocumentNode(id: nodeID, type: .object, depth: depth,
                                         parentID: parentID, childIDs: childIDs, key: key,
                                         value: .container(childCount: childIDs.count))
            return nodeID

        default:
            // Scalar leaf.
            let sv = scalarValue ?? .null
            let nodeID = NodeID.generate()
            nodes[nodeID] = DocumentNode(id: nodeID, type: .scalar, depth: depth,
                                         parentID: parentID, key: key, value: .scalar(sv))
            return nodeID
        }
    }
}
