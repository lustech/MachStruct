import Foundation

// MARK: - SchemaTypeKind

/// The type vocabulary of inferred schemas. `integer` and `number` are tracked
/// separately so int-only fields can render as `int`; mixing them widens to
/// `number` without flagging a conflict.
public enum SchemaTypeKind: String, Sendable, Hashable, CaseIterable {
    case object, array, string, integer, number, boolean, null
}

// MARK: - SchemaField

/// One named field of an inferred object schema.
public struct SchemaField: Sendable, Equatable {
    public let key: String
    /// Number of parent-object occurrences in which this key appeared.
    public let presence: Int
    /// True when `presence` is lower than the owning object's occurrence count.
    public let isOptional: Bool
    public let schema: SchemaNode

    /// Signature with the optionality marker applied (e.g. `string?`).
    public var displaySignature: String {
        let sig = schema.typeSignature
        if isOptional && !sig.hasSuffix("?") { return sig + "?" }
        return sig
    }
}

// MARK: - SchemaNode

/// The merged shape observed at one document path.
public struct SchemaNode: Sendable, Equatable {
    /// How many values were observed at this path.
    public let occurrences: Int
    /// Observation counts per type kind.
    public let kindCounts: [SchemaTypeKind: Int]
    /// Object fields in first-seen document order.
    public let fields: [SchemaField]
    /// True when children beyond the inference depth cap were not descended into.
    public let isDepthTruncated: Bool

    // Boxed in an array to break struct recursion.
    private let _element: [SchemaNode]
    /// Merged schema of array elements, if any array values were observed.
    public var element: SchemaNode? { _element.first }

    public init(occurrences: Int,
                kindCounts: [SchemaTypeKind: Int],
                fields: [SchemaField],
                element: SchemaNode?,
                isDepthTruncated: Bool) {
        self.occurrences = occurrences
        self.kindCounts = kindCounts
        self.fields = fields
        self._element = element.map { [$0] } ?? []
        self.isDepthTruncated = isDepthTruncated
    }

    /// Kind groups after widening: `integer`/`number` merge into one numeric
    /// group; `null` is excluded (it signals nullability, not a conflict).
    /// Sorted by count descending, ties in declaration order.
    private var effectiveGroups: [(name: String, count: Int)] {
        var groups: [(name: String, count: Int)] = []
        let ints = kindCounts[.integer] ?? 0
        let floats = kindCounts[.number] ?? 0
        for kind in SchemaTypeKind.allCases {
            switch kind {
            case .null, .number:
                continue   // null = nullability; floats fold into the int group
            case .integer:
                if ints + floats > 0 {
                    groups.append((floats > 0 ? "number" : "int", ints + floats))
                }
            case .boolean:
                if let count = kindCounts[kind], count > 0 {
                    groups.append(("bool", count))
                }
            default:
                if let count = kindCounts[kind], count > 0 {
                    groups.append((kind.rawValue, count))
                }
            }
        }
        return groups.sorted { $0.count > $1.count }
    }

    /// True when observations mix incompatible kinds (after int/number widening
    /// and ignoring nulls).
    public var hasKindConflict: Bool { effectiveGroups.count >= 2 }

    /// Human-readable type signature, e.g. `string`, `number?`, `object[]`,
    /// `int | string`.
    public var typeSignature: String {
        let groups = effectiveGroups
        let hasNull = (kindCounts[.null] ?? 0) > 0

        switch groups.count {
        case 0:
            return hasNull ? "null" : "unknown"
        case 1:
            var sig = groups[0].name
            if sig == "array" {
                sig = arraySignature
            }
            return hasNull ? sig + "?" : sig
        default:
            return groups.map(\.name).joined(separator: " | ")
        }
    }

    /// Signature for a pure-array node: `string[]` / `object[]` when the
    /// element type is simple, plain `array` otherwise.
    private var arraySignature: String {
        guard let element else { return "array" }
        let elemSig = element.typeSignature
        let isSimple = !elemSig.contains(" ") && !elemSig.hasSuffix("?")
            && !elemSig.hasSuffix("]") && elemSig != "unknown"
        return isSimple ? elemSig + "[]" : "array"
    }
}

// MARK: - SchemaInconsistency

/// A detected type inconsistency, e.g.
/// `$.items[].age — mostly int, but string in 3 of 10000`.
public struct SchemaInconsistency: Sendable, Equatable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

// MARK: - InferredSchema

/// Result of running schema inference over a document (or subtree).
public struct InferredSchema: Sendable, Equatable {
    public let root: SchemaNode
    /// Number of value nodes (objects, arrays, scalars) observed.
    public let nodesScanned: Int

    public init(root: SchemaNode, nodesScanned: Int) {
        self.root = root
        self.nodesScanned = nodesScanned
    }

    /// All type inconsistencies found anywhere in the schema tree,
    /// in document order.
    public var inconsistencies: [SchemaInconsistency] {
        var result: [SchemaInconsistency] = []
        collectInconsistencies(node: root, path: "$", into: &result)
        return result
    }

    private func collectInconsistencies(node: SchemaNode,
                                        path: String,
                                        into result: inout [SchemaInconsistency]) {
        if let message = node.conflictDescription {
            result.append(SchemaInconsistency(path: path, message: message))
        }
        for field in node.fields {
            collectInconsistencies(node: field.schema,
                                   path: path + "." + field.key, into: &result)
        }
        if let element = node.element {
            collectInconsistencies(node: element, path: path + "[]", into: &result)
        }
    }
}

public extension SchemaNode {
    /// Conflict description like "mostly int, but string in 3 of 10000",
    /// or nil when the node has no kind conflict.
    var conflictDescription: String? {
        let groups = effectiveGroups
        guard groups.count >= 2 else { return nil }
        let minorities = groups.dropFirst()
            .map { "\($0.name) in \($0.count) of \(occurrences)" }
            .joined(separator: ", ")
        return "mostly \(groups[0].name), but \(minorities)"
    }
}

// MARK: - Text rendering (Copy Schema)

public extension InferredSchema {
    /// Indented plain-text rendering of the schema, e.g. for copying:
    /// ```
    /// root: object
    ///   items: object[]
    ///     []: object
    ///       age: int | string   ⚠ mostly int, but string in 1 of 3
    /// ```
    var renderedText: String {
        Self.renderText(node: root, name: "root", optionalMark: false, indent: 0)
    }

    private static func renderText(node: SchemaNode, name: String,
                                   optionalMark: Bool, indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        var sig = node.typeSignature
        if optionalMark && !sig.hasSuffix("?") { sig += "?" }
        var line = "\(pad)\(name): \(sig)"
        if let summary = node.conflictDescription {
            line += "   ⚠ \(summary)"
        }
        var out = [line]
        for field in node.fields {
            out.append(renderText(node: field.schema, name: field.key,
                                  optionalMark: field.isOptional, indent: indent + 1))
        }
        if let element = node.element {
            out.append(renderText(node: element, name: "[]",
                                  optionalMark: false, indent: indent + 1))
        }
        if node.isDepthTruncated {
            out.append("\(pad)  …")
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - SchemaInferenceEngine

/// X-Ray Mode: infers the implicit schema of a document.
///
/// Follows the `SearchEngine` pattern for large files — a single linear pass
/// over `StructuralIndex.entries` with no `NodeIndex` materialisation, reading
/// keys and scalar kinds from mmap'd bytes only where the index lacks eager
/// values (simdjson path). Runs synchronously — call from a background task.
public enum SchemaInferenceEngine {

    // MARK: Builder (internal mutable aggregation node)

    private final class NodeBuilder {
        let depth: Int
        var occurrences = 0
        var kindCounts: [SchemaTypeKind: Int] = [:]
        var fieldOrder: [String] = []
        var fieldPresence: [String: Int] = [:]
        var fieldBuilders: [String: NodeBuilder] = [:]
        var element: NodeBuilder?
        var isDepthTruncated = false

        init(depth: Int) { self.depth = depth }

        func observe(_ kind: SchemaTypeKind) {
            occurrences += 1
            kindCounts[kind, default: 0] += 1
        }

        /// Field builder for `key`, incrementing presence. Returns nil (and
        /// marks truncation) past `maxDepth`.
        func fieldBuilder(for key: String, maxDepth: Int) -> NodeBuilder? {
            guard depth + 1 <= maxDepth else {
                isDepthTruncated = true
                return nil
            }
            fieldPresence[key, default: 0] += 1
            if let existing = fieldBuilders[key] { return existing }
            let created = NodeBuilder(depth: depth + 1)
            fieldBuilders[key] = created
            fieldOrder.append(key)
            return created
        }

        func elementBuilder(maxDepth: Int) -> NodeBuilder? {
            guard depth + 1 <= maxDepth else {
                isDepthTruncated = true
                return nil
            }
            if let element { return element }
            let created = NodeBuilder(depth: depth + 1)
            element = created
            return created
        }

        func build() -> SchemaNode {
            let objectCount = kindCounts[.object] ?? 0
            let fields = fieldOrder.map { key -> SchemaField in
                let presence = fieldPresence[key] ?? 0
                return SchemaField(key: key,
                                   presence: presence,
                                   isOptional: presence < objectCount,
                                   schema: fieldBuilders[key]!.build())
            }
            return SchemaNode(occurrences: occurrences,
                              kindCounts: kindCounts,
                              fields: fields,
                              element: element?.build(),
                              isDepthTruncated: isDepthTruncated)
        }
    }

    // MARK: - Large files

    /// Infer from a large document: nodes in `index` (which may be edited)
    /// are read from there, everything else is built from `source`.
    public static func infer(from source: any DocumentSource,
                             overlaying index: NodeIndex,
                             rootID: NodeID? = nil,
                             maxDepth: Int = 100) -> InferredSchema {
        infer(startID: rootID ?? index.rootID, file: nil, maxDepth: maxDepth) { id in
            index.node(for: id) ?? source.node(for: id, parent: nil, internKeys: false)
        }
    }

    // MARK: - NodeIndex path (small files)

    /// Infer from a fully materialised `NodeIndex` (small files, where the
    /// structural index is not retained). `file` is used to decode any
    /// still-`.unparsed` scalars from their source bytes.
    public static func infer(from index: NodeIndex,
                             file: MappedFile? = nil,
                             rootID: NodeID? = nil,
                             maxDepth: Int = 100) -> InferredSchema {
        infer(startID: rootID ?? index.rootID, file: file, maxDepth: maxDepth) {
            index.node(for: $0)
        }
    }

    private static func infer(startID: NodeID,
                              file: MappedFile?,
                              maxDepth: Int,
                              node lookup: (NodeID) -> DocumentNode?) -> InferredSchema {
        let rootBuilder = NodeBuilder(depth: 0)
        guard lookup(startID) != nil else {
            return InferredSchema(root: rootBuilder.build(), nodesScanned: 0)
        }

        var scanned = 0
        var visited = 0
        // Explicit stack — pathological files nest thousands of levels deep.
        // Children are pushed in reverse so they pop in document order.
        var stack: [(nodeID: NodeID, builder: NodeBuilder?)] = [(startID, rootBuilder)]

        while let (nodeID, builder) = stack.popLast() {
            visited += 1
            if visited & 0x3FFF == 0, Task.isCancelled { break }
            guard let node = lookup(nodeID) else { continue }

            switch node.type {
            case .keyValue:
                // Root-of-subtree keyValue: fold children into current builder.
                for childID in node.childIDs.reversed() {
                    stack.append((childID, builder))
                }

            case .object:
                builder?.observe(.object)
                if builder != nil { scanned += 1 }
                // Resolve field builders in forward order (fields record
                // first-seen document order), then push reversed so values
                // pop in document order.
                var pushes: [(NodeID, NodeBuilder?)] = []
                for childID in node.childIDs {
                    guard let child = lookup(childID) else { continue }
                    if child.type == .keyValue {
                        guard let key = child.key else { continue }
                        let fieldBuilder = builder?.fieldBuilder(for: key,
                                                                 maxDepth: maxDepth)
                        for grandChildID in child.childIDs {
                            pushes.append((grandChildID, fieldBuilder))
                        }
                    } else if let key = child.key {
                        pushes.append((childID,
                                       builder?.fieldBuilder(for: key,
                                                             maxDepth: maxDepth)))
                    } else {
                        pushes.append((childID,
                                       builder?.elementBuilder(maxDepth: maxDepth)))
                    }
                }
                stack.append(contentsOf: pushes.reversed())

            case .array:
                builder?.observe(.array)
                if builder != nil { scanned += 1 }
                // An empty array has no element schema.
                let elementBuilder = node.childIDs.isEmpty
                    ? nil : builder?.elementBuilder(maxDepth: maxDepth)
                for childID in node.childIDs.reversed() {
                    stack.append((childID, elementBuilder))
                }

            case .scalar:
                guard let builder else { continue }
                let kind: SchemaTypeKind?
                switch node.value {
                case .scalar(let sv):
                    kind = scalarKind(of: sv)
                case .unparsed:
                    kind = sniffScalarKind(offset: node.sourceRange.byteOffset,
                                           length: node.sourceRange.byteLength,
                                           file: file)
                default:
                    kind = nil
                }
                if let kind {
                    builder.observe(kind)
                    scanned += 1
                }
            }
        }

        return InferredSchema(root: rootBuilder.build(), nodesScanned: scanned)
    }

    // MARK: - Key / scalar-kind resolution

    private static func scalarKind(of value: ScalarValue) -> SchemaTypeKind {
        switch value {
        case .string:  return .string
        case .integer: return .integer
        case .float:   return .number
        case .boolean: return .boolean
        case .null:    return .null
        }
    }

    /// Determine a scalar's kind from its raw JSON bytes without full parsing:
    /// first byte discriminates string/bool/null; numbers are `int` unless the
    /// token contains `.`, `e`, or `E`.
    private static func sniffScalarKind(offset: UInt64, length: UInt32,
                                        file: MappedFile?) -> SchemaTypeKind? {
        guard let file, length > 0,
              let bytes = try? file.slice(offset: offset, length: length)
        else { return nil }
        switch bytes[0] {
        case UInt8(ascii: "\""):
            return .string
        case UInt8(ascii: "t"), UInt8(ascii: "f"):
            return .boolean
        case UInt8(ascii: "n"):
            return .null
        default:
            for b in bytes where b == UInt8(ascii: ".")
                || b == UInt8(ascii: "e") || b == UInt8(ascii: "E") {
                return .number
            }
            return .integer
        }
    }
}
