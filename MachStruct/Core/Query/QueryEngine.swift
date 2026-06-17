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

    /// Run `query` against the fully- or partially-materialised `index`.
    public func run(_ query: String, on index: NodeIndex) async throws -> Result {
        let expr: JQExpr
        do {
            expr = try JQParser.parse(query)
        } catch let e as JQParseError {
            throw QueryError.parse(e)
        }

        try Task.checkCancellation()

        let input = JQValue(node: index.rootID, in: index)

        let values: [JQValue]
        do {
            values = try JQEvaluator.evaluate(expr, against: input)
        } catch let e as JQRuntimeError {
            throw QueryError.runtime(e)
        }

        try Task.checkCancellation()

        // Resolve source nodes only for path-only queries, and only when the
        // resolved count matches the evaluated output (a safety check that the
        // two traversals stayed aligned).
        var sourceNodeIDs: [NodeID]? = nil
        if JQPath.isPathOnly(expr) {
            let ids = (try? JQPath.resolve(expr, from: [index.rootID], in: index)) ?? []
            if ids.count == values.count {
                sourceNodeIDs = ids
            }
        }

        return Result(values: values, sourceNodeIDs: sourceNodeIDs)
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
    static func resolve(_ expr: JQExpr, from nodeIDs: [NodeID], in index: NodeIndex) throws -> [NodeID] {
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

    // MARK: Helpers

    private static func isConstant(_ expr: JQExpr) -> Bool {
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
