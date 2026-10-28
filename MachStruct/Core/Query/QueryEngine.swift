import Foundation

// MARK: - QueryEngine

/// Orchestrates running a jq query against a document: parse → project the
/// document onto a `JQValue` → evaluate → (optionally) resolve outputs back to
/// source `NodeID`s for path-only queries.
///
/// An `actor` so a long-running query on a large file runs off the main actor;
/// callers cancel by cancelling the surrounding `Task`.
public actor QueryEngine {

    public init() {}

    // MARK: Result & errors

    public struct Result: Sendable {
        /// The query's output values, in document order.
        public let values: [JQValue]

        /// For *path-only* queries (no value construction), the source node for
        /// each output value, aligned 1:1 with `values`.  `nil` when the query
        /// constructs new values and outputs cannot be mapped back to the
        /// document (so "apply to document" is unavailable).
        public let sourceNodeIDs: [NodeID]?

        public init(values: [JQValue], sourceNodeIDs: [NodeID]?) {
            self.values = values
            self.sourceNodeIDs = sourceNodeIDs
        }
    }

    public enum QueryError: Error {
        case parse(JQParseError)
        case runtime(JQRuntimeError)
    }

    // MARK: Run

    /// Run `query` against `document`: a `NodeIndex`, or a large file's
    /// `DocumentOverlay`.
    ///
    /// The whole document is projected onto a `JQValue` only when it has to
    /// be. A query that navigates to one node (`.a[0].b`) reads just that
    /// node, and one that iterates a container it navigates to and goes on
    /// from each item (`.[] | select(.x > 1)`, `.rows[].name`) projects one
    /// item at a time, keeping only the outputs.
    public func run<Lookup: NodeLookup>(_ query: String, on document: Lookup) async throws -> Result {
        let expr: JQExpr
        do {
            expr = try JQParser.parse(query)
        } catch let e as JQParseError {
            throw QueryError.parse(e)
        }

        try Task.checkCancellation()

        let pathOnly = JQPath.isPathOnly(expr)
        var values: [JQValue] = []
        // Resolve source nodes only for path-only queries, and only when the
        // resolved count matches the evaluated output (a safety check that the
        // two traversals stayed aligned).
        var ids: [NodeID]? = pathOnly ? [] : nil
        do {
            if let target = JQPath.navigate(expr, in: document) {
                values = [JQValue(node: target, in: document)]
                ids = pathOnly ? [target] : nil
            } else if let (items, rest) = JQPath.splitAtIteration(expr, in: document) {
                // `expr` is `P | .[] | rest`, and jq runs `rest` on each item
                // in turn, so the outputs are each item's, in order.
                for (n, item) in items.enumerated() {
                    if n & 0x3FF == 0 { try Task.checkCancellation() }
                    values += try JQEvaluator.evaluate(rest, against: JQValue(node: item, in: document))
                    if ids != nil {
                        if let found = try? JQPath.resolve(rest, from: [item], in: document) {
                            ids! += found
                        } else {
                            ids = nil
                        }
                    }
                }
            } else {
                values = try JQEvaluator.evaluate(expr, against: JQValue(node: document.rootID,
                                                                           in: document))
                try Task.checkCancellation()
                ids = pathOnly ? (try? JQPath.resolve(expr, from: [document.rootID], in: document)) : nil
            }
        } catch let e as JQRuntimeError {
            throw QueryError.runtime(e)
        }

        try Task.checkCancellation()
        if let found = ids, found.count != values.count { ids = nil }
        return Result(values: values, sourceNodeIDs: ids)
    }
}

// MARK: - JQPath

/// Maps a *path-only* jq query back onto the document nodes it selects.
///
/// A query is path-only when every step navigates existing structure
/// (`identity`, `field`, `index`, `iterate`, `pipe`, `comma`, `select`,
/// `values`) and never constructs new values.  Only such queries can be applied
/// back to the document (delete-matched / set-value).
enum JQPath {

    static func isPathOnly(_ expr: JQExpr) -> Bool {
        switch expr {
        case .identity:
            return true
        case .field(let base, _, _):
            return isPathOnly(base)
        case .index(let base, let idx, _):
            // The index must be a constant (input-independent) so it resolves to
            // a fixed child position.
            return isPathOnly(base) && isConstant(idx)
        case .iterate(let base, _):
            return isPathOnly(base)
        case .pipe(let a, let b), .comma(let a, let b):
            return isPathOnly(a) && isPathOnly(b)
        case .call(let name, let args):
            switch (name, args.count) {
            case ("select", 1): return true   // filters nodes, never constructs
            case ("values", 0): return true
            default:            return false
            }
        // slice/binary/and/or/negate/literal/array/object all construct or
        // transform values and cannot map back to a single source node.
        default:
            return false
        }
    }

    /// Resolve the node IDs selected by a path-only `expr`, starting from
    /// `nodeIDs`, in document order.
    static func resolve<Lookup: NodeLookup>(_ expr: JQExpr, from nodeIDs: [NodeID],
                                            in index: Lookup) throws -> [NodeID] {
        switch expr {
        case .identity:
            return nodeIDs

        case .field(let base, let name, let optional):
            let bases = try resolve(base, from: nodeIDs, in: index)
            var out: [NodeID] = []
            for baseID in bases {
                guard let node = index.node(for: baseID) else { continue }
                if node.type == .object {
                    if let kvID = node.childIDs.first(where: { index.node(for: $0)?.key == name }),
                       let valueID = index.node(for: kvID)?.childIDs.first {
                        out.append(valueID)
                    }
                    // Missing key → null with no node; skip (can't map back).
                } else if !optional {
                    throw JQRuntimeError("Cannot index \(jqTypeName(node)) with \"\(name)\"")
                }
            }
            return out

        case .index(let base, let idxExpr, let optional):
            let bases = try resolve(base, from: nodeIDs, in: index)
            // Constant index resolved against null input.
            let idxValues = try JQEvaluator.evaluate(idxExpr, against: .null)
            var out: [NodeID] = []
            for baseID in bases {
                guard let node = index.node(for: baseID) else { continue }
                for idxValue in idxValues {
                    if node.type == .array, case .int(let i) = idxValue {
                        let n = node.childIDs.count
                        let pos = i < 0 ? Int(i) + n : Int(i)
                        if pos >= 0 && pos < n { out.append(node.childIDs[pos]) }
                    } else if node.type == .object, case .string(let key) = idxValue {
                        if let kvID = node.childIDs.first(where: { index.node(for: $0)?.key == key }),
                           let valueID = index.node(for: kvID)?.childIDs.first {
                            out.append(valueID)
                        }
                    } else if !optional {
                        throw JQRuntimeError("Cannot index \(jqTypeName(node))")
                    }
                }
            }
            return out

        case .iterate(let base, let optional):
            let bases = try resolve(base, from: nodeIDs, in: index)
            var out: [NodeID] = []
            for baseID in bases {
                guard let node = index.node(for: baseID) else { continue }
                switch node.type {
                case .array:
                    out.append(contentsOf: node.childIDs)
                case .object:
                    for kvID in node.childIDs {
                        if let valueID = index.node(for: kvID)?.childIDs.first {
                            out.append(valueID)
                        }
                    }
                default:
                    if !optional { throw JQRuntimeError("Cannot iterate over \(jqTypeName(node))") }
                }
            }
            return out

        case .pipe(let a, let b):
            return try resolve(b, from: resolve(a, from: nodeIDs, in: index), in: index)

        case .comma(let a, let b):
            return try resolve(a, from: nodeIDs, in: index) + resolve(b, from: nodeIDs, in: index)

        case .call("select", let args) where args.count == 1:
            var out: [NodeID] = []
            for nodeID in nodeIDs {
                let projection = JQValue(node: nodeID, in: index)
                let results = try JQEvaluator.evaluate(args[0], against: projection)
                if results.contains(where: { truthy($0) }) { out.append(nodeID) }
            }
            return out

        case .call("values", let args) where args.isEmpty:
            return nodeIDs.filter { JQValue(node: $0, in: index) != .null }

        default:
            throw JQRuntimeError("Query is not a path expression")
        }
    }

    // MARK: Navigation

    /// The node `expr` selects when it only navigates down from the root by
    /// field names and constant indices (`.a[0].b`), and every step finds a
    /// member or item; otherwise `nil`, and the query is evaluated as usual.
    static func navigate<Lookup: NodeLookup>(_ expr: JQExpr, in document: Lookup) -> NodeID? {
        switch expr {
        case .identity:
            return document.rootID

        case .field(let base, let name, _):
            guard let id = navigate(base, in: document) else { return nil }
            return member(name, of: id, in: document)

        case .index(let base, let indexExpr, _):
            guard isConstant(indexExpr), let id = navigate(base, in: document),
                  let node = document.node(for: id),
                  let indices = try? JQEvaluator.evaluate(indexExpr, against: .null),
                  indices.count == 1 else { return nil }
            switch (node.type, indices[0]) {
            case (.array, .int(let i)):
                let n = node.childIDs.count
                let pos = i < 0 ? Int(i) + n : Int(i)
                return pos >= 0 && pos < n ? node.childIDs[pos] : nil
            case (.object, .string(let key)):
                return member(key, of: id, in: document)
            default:
                return nil
            }

        default:
            return nil
        }
    }

    /// The value of the first member named `name` of the object `id`, as
    /// `.name` reads it.
    private static func member<Lookup: NodeLookup>(_ name: String, of id: NodeID,
                                                    in document: Lookup) -> NodeID? {
        guard let node = document.node(for: id), node.type == .object,
              let kvID = node.childIDs.first(where: { document.node(for: $0)?.key == name })
        else { return nil }
        return document.node(for: kvID)?.childIDs.first
    }

    /// Splits `expr` into `P | .[] | rest`, where `P` navigates to a container
    /// (see `navigate`), returning the container's items — what `.[]` yields —
    /// and `rest`. `nil` if `expr` doesn't have that shape.
    static func splitAtIteration<Lookup: NodeLookup>(_ expr: JQExpr, in document: Lookup)
        -> (items: [NodeID], rest: JQExpr)? {
        switch expr {
        case .iterate(let base, let optional):
            if let id = navigate(base, in: document), let items = items(of: id, in: document) {
                return (items, .identity)
            }
            return splitAtIteration(base, in: document)
                .map { ($0.items, .iterate(base: $0.rest, optional: optional)) }

        // Each of these runs on every output of its base in turn, as a pipe's
        // right side does.
        case .pipe(let lhs, let rhs):
            return splitAtIteration(lhs, in: document).map { ($0.items, .pipe($0.rest, rhs)) }
        case .field(let base, let name, let optional):
            return splitAtIteration(base, in: document)
                .map { ($0.items, .field(base: $0.rest, name: name, optional: optional)) }
        case .index(let base, let indexExpr, let optional)
            where isConstant(indexExpr) && (try? JQEvaluator.evaluate(indexExpr, against: .null)) != nil:
            // A constant index doesn't depend on the input it's evaluated on,
            // and evaluates without error even when there are no items.
            return splitAtIteration(base, in: document)
                .map { ($0.items, .index(base: $0.rest, index: indexExpr, optional: optional)) }

        default:
            return nil
        }
    }

    /// What `.[]` yields for the node `id`: an array's items or an object's
    /// member values. `nil` for anything else, or a member without a value.
    private static func items<Lookup: NodeLookup>(of id: NodeID, in document: Lookup) -> [NodeID]? {
        guard let node = document.node(for: id) else { return nil }
        switch node.type {
        case .array:
            return node.childIDs
        case .object:
            var values: [NodeID] = []
            values.reserveCapacity(node.childIDs.count)
            for kvID in node.childIDs {
                guard let valueID = document.node(for: kvID)?.childIDs.first else { return nil }
                values.append(valueID)
            }
            return values
        default:
            return nil
        }
    }

    // MARK: Helpers

    static func isConstant(_ expr: JQExpr) -> Bool {
        switch expr {
        case .literal:               return true
        case .negate(let e):         return isConstant(e)
        case .binary(_, let l, let r): return isConstant(l) && isConstant(r)
        default:                     return false
        }
    }

    private static func truthy(_ v: JQValue) -> Bool {
        switch v {
        case .null, .bool(false): return false
        default:                  return true
        }
    }

    private static func jqTypeName(_ node: DocumentNode) -> String {
        switch node.type {
        case .object:   return "object"
        case .array:    return "array"
        case .keyValue: return "object"
        case .scalar:
            if case .scalar(let sv) = node.value { return JQValue(scalar: sv).typeName }
            return "null"
        }
    }
}
