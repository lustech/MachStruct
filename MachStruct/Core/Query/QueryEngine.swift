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
        // The nodes of a path-only query's outputs, when each output is one.
        var ids: [NodeID]? = pathOnly ? [] : nil
        var locating = pathOnly
        func run(_ expr: JQExpr, on node: NodeID) throws {
            let input = JQValue(node: node, in: document)
            guard pathOnly else {
                values += try JQEvaluator.evaluate(expr, against: input)
                return
            }
            for output in try JQPath.evaluate(expr, on: .init(value: input, node: node),
                                              locating: &locating, in: document) {
                values.append(output.value)
                if let node = output.node { ids?.append(node) } else { locating = false }
            }
        }
        do {
            if let target = JQPath.navigate(expr, in: document) {
                values = [JQValue(node: target, in: document)]
                ids = pathOnly ? [target] : nil
            } else if let (items, rest) = JQPath.splitAtIteration(expr, in: document) {
                // `expr` is `P | .[] | rest`, and jq runs `rest` on each item
                // in turn, so the outputs are each item's, in order.
                for (n, item) in items.enumerated() {
                    if n & 0x3FF == 0 { try Task.checkCancellation() }
                    try run(rest, on: item)
                }
            } else {
                try run(expr, on: document.rootID)
            }
            if !locating { ids = nil }
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

    // MARK: Values with their nodes

    /// A value a path-only query outputs, with the node it is, or `nil` when
    /// it isn't one (a missing member reads as `null`) or that is unknown.
    struct Located {
        let value: JQValue
        let node: NodeID?
    }

    /// Evaluates the path-only `expr` on `input` as `JQEvaluator` does, with
    /// each output's node: one pass where evaluating and then resolving the
    /// nodes took two. Each step's outputs come from the evaluator itself,
    /// so they and any error are exactly its; this only pairs them with the
    /// nodes they came from.
    ///
    /// Once one of the query's outputs has no node they can't all be mapped
    /// back, and the caller sets `locating` false so that nodes are no longer
    /// looked up. A value with no node that leads to no output is harmless.
    static func evaluate<Lookup: NodeLookup>(_ expr: JQExpr, on input: Located,
                                             locating: inout Bool,
                                             in document: Lookup) throws -> [Located] {
        func lookup(_ node: NodeID?, _ find: (DocumentNode) -> NodeID?) -> NodeID? {
            guard locating, let node else { return nil }
            return document.node(for: node).flatMap(find)
        }
        func located(_ values: [JQValue], _ node: NodeID?) -> [Located] {
            values.map { Located(value: $0, node: node) }
        }

        switch expr {
        case .identity:
            return [input]

        case .field(let base, let name, let optional):
            let step = JQExpr.field(base: .identity, name: name, optional: optional)
            return try evaluate(base, on: input, locating: &locating, in: document).flatMap { b -> [Located] in
                let values = try JQEvaluator.evaluate(step, against: b.value)
                guard !values.isEmpty else { return [] }
                return located(values, lookup(b.node) { member(name, of: $0, in: document) })
            }

        case .index(let base, let indexExpr, let optional):
            // As the evaluator: the bases, then the indices from this step's
            // input, then each index of each base.
            let bases = try evaluate(base, on: input, locating: &locating, in: document)
            let indices = try JQEvaluator.evaluate(indexExpr, against: input.value)
            var out: [Located] = []
            for b in bases {
                for idx in indices {
                    let step = JQExpr.index(base: .identity, index: .literal(idx), optional: optional)
                    let values = try JQEvaluator.evaluate(step, against: b.value)
                    guard !values.isEmpty else { continue }
                    out += located(values, lookup(b.node) { node in
                        switch (node.type, idx) {
                        case (.array, .int(let i)):
                            let n = node.childIDs.count
                            let pos = i < 0 ? Int(i) + n : Int(i)
                            return pos >= 0 && pos < n ? node.childIDs[pos] : nil
                        case (.object, .string(let key)):
                            return member(key, of: node, in: document)
                        default:
                            return nil
                        }
                    })
                }
            }
            return out

        case .iterate(let base, let optional):
            let step = JQExpr.iterate(base: .identity, optional: optional)
            return try evaluate(base, on: input, locating: &locating, in: document).flatMap { b -> [Located] in
                let values = try JQEvaluator.evaluate(step, against: b.value)
                guard locating, let id = b.node, let node = document.node(for: id) else {
                    return located(values, nil)
                }
                // An array's items, or an object's members' values: the
                // projection keeps every member, so they align.
                let items = node.type == .object
                    ? node.childIDs.compactMap { document.node(for: $0)?.childIDs.first }
                    : node.childIDs
                guard items.count == values.count else { return located(values, nil) }
                return zip(values, items).map { Located(value: $0, node: $1) }
            }

        case .pipe(let lhs, let rhs):
            var out: [Located] = []
            for o in try evaluate(lhs, on: input, locating: &locating, in: document) {
                out += try evaluate(rhs, on: o, locating: &locating, in: document)
            }
            return out

        case .comma(let lhs, let rhs):
            return try evaluate(lhs, on: input, locating: &locating, in: document)
                + evaluate(rhs, on: input, locating: &locating, in: document)

        default:
            // `select` and `values` output their input, as many times as
            // they output anything.
            return located(try JQEvaluator.evaluate(expr, against: input.value), input.node)
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
        document.node(for: id).flatMap { member(name, of: $0, in: document) }
    }

    private static func member<Lookup: NodeLookup>(_ name: String, of node: DocumentNode,
                                                    in document: Lookup) -> NodeID? {
        guard node.type == .object,
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
}
