import Foundation

// MARK: - JQBinaryOp

/// Infix arithmetic and comparison operators supported by the v2.0 jq subset.
public enum JQBinaryOp: String, Equatable, Sendable {
    case eq  = "=="
    case neq = "!="
    case lt  = "<"
    case le  = "<="
    case gt  = ">"
    case ge  = ">="
    case add = "+"
    case sub = "-"
    case mul = "*"
    case div = "/"
}

// MARK: - JQObjectEntry

/// A single member of an object-construction expression `{ key: value }`.
public struct JQObjectEntry: Equatable, Sendable {
    public let key: JQExpr
    public let value: JQExpr

    public init(key: JQExpr, value: JQExpr) {
        self.key = key
        self.value = value
    }
}

// MARK: - JQExpr

/// The abstract syntax tree for a parsed jq filter.
///
/// Path operations (`field`, `index`, `slice`, `iterate`) are modelled as
/// postfix operations on a `base` expression, so `.a.b[0][]` nests as
/// `iterate(index(field(field(identity, a), b), 0))`.  This makes path tracking
/// (mapping outputs back to source `NodeID`s) a simple structural walk.
public indirect enum JQExpr: Equatable, Sendable {
    case identity                                                   // .
    case field(base: JQExpr, name: String, optional: Bool)          // .foo  / .foo?
    case index(base: JQExpr, index: JQExpr, optional: Bool)         // .[expr]
    case slice(base: JQExpr, lower: JQExpr?, upper: JQExpr?, optional: Bool)  // .[lo:hi]
    case iterate(base: JQExpr, optional: Bool)                      // .[]
    case pipe(JQExpr, JQExpr)                                       // a | b
    case comma(JQExpr, JQExpr)                                      // a, b
    case binary(op: JQBinaryOp, lhs: JQExpr, rhs: JQExpr)           // a + b, a == b
    case and(JQExpr, JQExpr)                                        // a and b
    case or(JQExpr, JQExpr)                                         // a or b
    case negate(JQExpr)                                             // -a
    case literal(JQValue)                                          // 1, "x", true, null
    case array(JQExpr?)                                            // [ expr ]  (nil = [])
    case object([JQObjectEntry])                                  // { ... }
    case call(name: String, args: [JQExpr])                       // length, map(f), select(f)
}

// MARK: - JQParseError

/// A syntax error produced while parsing a jq query.
///
/// `column` is a 0-based offset into the source string, used by the query bar
/// to point at the offending token.
public struct JQParseError: Error, Equatable, Sendable {
    public let message: String
    public let column: Int

    public init(message: String, column: Int) {
        self.message = message
        self.column = column
    }
}
