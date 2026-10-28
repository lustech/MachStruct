import Foundation

// MARK: - JQDemand

/// What of its input a jq expression can read, so a query projects only
/// that much of each item: `.[] | select(.city == "x") | .name` reads two
/// members of each, and building every member's value took most of its time.
///
/// `parts` reads the named members of an object (the first of each name, as
/// `.name` does, so every member of that name is kept) and, with `each`,
/// every element of an array or member value of an object. Nothing else is
/// read, and a value projected for it keeps its type, which is all a field
/// access or iteration on the wrong type reports. Anything the analysis
/// doesn't know reads `all`, so a query can only skip what it never reads.
indirect enum JQDemand: Equatable {
    case all
    case parts(fields: [String: JQDemand], each: JQDemand?)

    static let none = JQDemand.parts(fields: [:], each: nil)

    func union(_ other: JQDemand) -> JQDemand {
        switch (self, other) {
        case (.all, _), (_, .all):
            return .all
        case let (.parts(f1, e1), .parts(f2, e2)):
            let each: JQDemand? = switch (e1, e2) {
            case let (a?, b?): a.union(b)
            case let (a?, nil): a
            case let (nil, b): b
            }
            return .parts(fields: f1.merging(f2) { $0.union($1) }, each: each)
        }
    }

    /// What `expr` reads of its input when what it outputs is read as `output`.
    static func of(_ expr: JQExpr, output: JQDemand = .all) -> JQDemand {
        switch expr {
        case .identity:
            return output

        case .literal:
            return .none

        case .field(let base, let name, _):
            return of(base, output: .parts(fields: [name: output], each: nil))

        case .index(let base, let index, _):
            // A constant key reads that member; other indices read the input
            // in whatever way (an array position needs the whole array). The
            // index expression reads this step's input.
            if JQPath.isConstant(index),
               let keys = try? JQEvaluator.evaluate(index, against: .null),
               keys.count == 1, case .string(let key) = keys[0] {
                return of(base, output: .parts(fields: [key: output], each: nil))
            }
            return of(base, output: .all).union(of(index))

        case .iterate(let base, _):
            return of(base, output: .parts(fields: [:], each: output))

        case .pipe(let lhs, let rhs):
            return of(lhs, output: of(rhs, output: output))

        case .comma(let lhs, let rhs):
            return of(lhs, output: output).union(of(rhs, output: output))

        case .slice(let base, let lower, let upper, _):
            return [base, lower, upper].compactMap { $0 }.map { of($0) }.reduce(.none) { $0.union($1) }

        case .binary(_, let lhs, let rhs), .and(let lhs, let rhs), .or(let lhs, let rhs):
            return of(lhs).union(of(rhs))

        case .negate(let operand):
            return of(operand)

        case .array(let element):
            return element.map { of($0) } ?? .none

        case .object(let entries):
            return entries.reduce(.none) { $0.union(of($1.key)).union(of($1.value)) }

        case .call(let name, let args):
            switch (name, args.count) {
            case ("select", 1):
                // Outputs its input, after reading it with the condition.
                return output.union(of(args[0]))
            case ("values", 0):
                // Outputs its input unless it is null, which a projection keeps.
                return output
            case ("map", 1):
                return .parts(fields: [:], each: of(args[0]))
            default:
                return .all
            }
        }
    }
}
