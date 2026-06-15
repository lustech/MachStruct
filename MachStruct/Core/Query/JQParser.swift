import Foundation

// MARK: - JQParser

/// Recursive-descent parser for the v2.0 jq subset.
///
/// Precedence, lowest to highest: pipe `|` → comma `,` → `or` → `and` →
/// comparison → additive → multiplicative → unary minus → postfix path ops →
/// primary.  Path operations (`.foo`, `[…]`, `[]`) are postfix on a base
/// expression.
///
/// Throws `JQParseError` with a 0-based column for any malformed input.
final class JQParser {

    private let tokens: [JQToken]
    private var pos = 0

    private init(tokens: [JQToken]) { self.tokens = tokens }

    /// Parse `source` into a `JQExpr`, or throw `JQParseError`.
    static func parse(_ source: String) throws -> JQExpr {
        let tokens = try JQLexer.tokenize(source)
        let parser = JQParser(tokens: tokens)
        let expr = try parser.parsePipe()
        try parser.expect(.eof, "unexpected trailing input")
        return expr
    }

    // MARK: - Token cursor

    private var current: JQToken { tokens[pos] }

    private func advance() -> JQToken {
        defer { if pos < tokens.count - 1 { pos += 1 } }
        return tokens[pos]
    }

    private func match(_ kind: JQToken.Kind) -> Bool {
        if current.kind == kind { pos += 1; return true }
        return false
    }

    private func expect(_ kind: JQToken.Kind, _ message: String) throws {
        guard current.kind == kind else {
            throw JQParseError(message: message, column: current.column)
        }
        pos += 1
    }

    // MARK: - Precedence levels

    /// pipe := comma ('|' comma)*
    private func parsePipe() throws -> JQExpr {
        var lhs = try parseComma()
        while match(.pipe) {
            let rhs = try parseComma()
            lhs = .pipe(lhs, rhs)
        }
        return lhs
    }

    /// comma := or (',' or)*
    private func parseComma() throws -> JQExpr {
        var lhs = try parseOr()
        while match(.comma) {
            let rhs = try parseOr()
            lhs = .comma(lhs, rhs)
        }
        return lhs
    }

    /// or := and ('or' and)*
    private func parseOr() throws -> JQExpr {
        var lhs = try parseAnd()
        while case .identifier("or") = current.kind {
            pos += 1
            let rhs = try parseAnd()
            lhs = .or(lhs, rhs)
        }
        return lhs
    }

    /// and := comparison ('and' comparison)*
    private func parseAnd() throws -> JQExpr {
        var lhs = try parseComparison()
        while case .identifier("and") = current.kind {
            pos += 1
            let rhs = try parseComparison()
            lhs = .and(lhs, rhs)
        }
        return lhs
    }

    /// comparison := additive (compop additive)?   (non-associative)
    private func parseComparison() throws -> JQExpr {
        let lhs = try parseAdditive()
        if case .op(let op) = current.kind,
           [.eq, .neq, .lt, .le, .gt, .ge].contains(op) {
            pos += 1
            let rhs = try parseAdditive()
            return .binary(op: op, lhs: lhs, rhs: rhs)
        }
        return lhs
    }

    /// additive := multiplicative (('+'|'-') multiplicative)*
    private func parseAdditive() throws -> JQExpr {
        var lhs = try parseMultiplicative()
        while case .op(let op) = current.kind, op == .add || op == .sub {
            pos += 1
            let rhs = try parseMultiplicative()
            lhs = .binary(op: op, lhs: lhs, rhs: rhs)
        }
        return lhs
    }

    /// multiplicative := unary (('*'|'/') unary)*
    private func parseMultiplicative() throws -> JQExpr {
        var lhs = try parseUnary()
        while case .op(let op) = current.kind, op == .mul || op == .div {
            pos += 1
            let rhs = try parseUnary()
            lhs = .binary(op: op, lhs: lhs, rhs: rhs)
        }
        return lhs
    }

    /// unary := '-' unary | postfix
    private func parseUnary() throws -> JQExpr {
        if case .op(.sub) = current.kind {
            pos += 1
            let operand = try parseUnary()
            // Fold a unary minus on a numeric literal into a negative literal.
            switch operand {
            case .literal(.int(let n)):    return .literal(.int(-n))
            case .literal(.double(let d)): return .literal(.double(-d))
            default:                       return .negate(operand)
            }
        }
        return try parsePostfix()
    }

    // MARK: - Postfix path operations

    /// postfix := primary suffix*
    private func parsePostfix() throws -> JQExpr {
        var base = try parsePrimary()
        while true {
            if isFieldSuffix() {
                pos += 1   // consume '.'
                let name = try parseFieldName()
                let optional = match(.question)
                base = .field(base: base, name: name, optional: optional)
            } else if current.kind == .lbracket {
                base = try parseBracketSuffix(base: base)
            } else {
                break
            }
        }
        return base
    }

    /// True when the cursor is at a `.name` / `."name"` field suffix.
    private func isFieldSuffix() -> Bool {
        guard current.kind == .dot else { return false }
        switch tokens[pos + 1].kind {
        case .identifier, .string: return true
        default:                   return false
        }
    }

    private func parseFieldName() throws -> String {
        switch current.kind {
        case .identifier(let n): pos += 1; return n
        case .string(let s):     pos += 1; return s
        default:
            throw JQParseError(message: "expected field name after '.'", column: current.column)
        }
    }

    /// bracket := '[' (']' | expr ']' | expr ':' expr ']' | ':' expr ']' | expr ':' ']') '?'?
    private func parseBracketSuffix(base: JQExpr) throws -> JQExpr {
        try expect(.lbracket, "expected '['")

        // Iterate: `[]`
        if match(.rbracket) {
            let optional = match(.question)
            return .iterate(base: base, optional: optional)
        }

        // Slice with no lower bound: `[:hi]`
        if match(.colon) {
            let upper = try parsePipe()
            try expect(.rbracket, "expected ']' to close slice")
            let optional = match(.question)
            return .slice(base: base, lower: nil, upper: upper, optional: optional)
        }

        let first = try parsePipe()

        // Slice: `[lo:hi]` or `[lo:]`
        if match(.colon) {
            var upper: JQExpr? = nil
            if current.kind != .rbracket {
                upper = try parsePipe()
            }
            try expect(.rbracket, "expected ']' to close slice")
            let optional = match(.question)
            return .slice(base: base, lower: first, upper: upper, optional: optional)
        }

        // Index: `[expr]`
        try expect(.rbracket, "expected ']' to close index")
        let optional = match(.question)
        return .index(base: base, index: first, optional: optional)
    }

    // MARK: - Primary

    private func parsePrimary() throws -> JQExpr {
        switch current.kind {

        case .dot:
            pos += 1
            // `.name` / `."name"` — field on identity.
            switch current.kind {
            case .identifier(let n):
                pos += 1
                let optional = match(.question)
                return .field(base: .identity, name: n, optional: optional)
            case .string(let s):
                pos += 1
                let optional = match(.question)
                return .field(base: .identity, name: s, optional: optional)
            default:
                // Bare `.` (identity) — any `[…]` that follows is a postfix suffix.
                return .identity
            }

        case .number(let v):
            pos += 1
            return .literal(v)

        case .string(let s):
            pos += 1
            return .literal(.string(s))

        case .identifier(let name):
            pos += 1
            switch name {
            case "true":  return .literal(.bool(true))
            case "false": return .literal(.bool(false))
            case "null":  return .literal(.null)
            default:      return try parseCall(name: name)
            }

        case .lbracket:
            return try parseArrayConstruct()

        case .lbrace:
            return try parseObjectConstruct()

        case .lparen:
            pos += 1
            let inner = try parsePipe()
            try expect(.rparen, "expected ')'")
            return inner

        case .eof:
            throw JQParseError(message: "unexpected end of query", column: current.column)

        default:
            throw JQParseError(message: "unexpected token", column: current.column)
        }
    }

    /// A bare identifier is a function call: `length`, `map(f)`, `select(f)`.
    private func parseCall(name: String) throws -> JQExpr {
        guard match(.lparen) else {
            return .call(name: name, args: [])
        }
        var args: [JQExpr] = []
        if current.kind != .rparen {
            args.append(try parsePipe())
            while match(.semicolon) {
                args.append(try parsePipe())
            }
        }
        try expect(.rparen, "expected ')' to close arguments to '\(name)'")
        return .call(name: name, args: args)
    }

    private func parseArrayConstruct() throws -> JQExpr {
        try expect(.lbracket, "expected '['")
        if match(.rbracket) { return .array(nil) }
        let inner = try parsePipe()
        try expect(.rbracket, "expected ']' to close array")
        return .array(inner)
    }

    private func parseObjectConstruct() throws -> JQExpr {
        try expect(.lbrace, "expected '{'")
        var entries: [JQObjectEntry] = []
        if current.kind != .rbrace {
            repeat {
                entries.append(try parseObjectEntry())
            } while match(.comma)
        }
        try expect(.rbrace, "expected '}' to close object")
        return .object(entries)
    }

    private func parseObjectEntry() throws -> JQObjectEntry {
        // Key: identifier | string | (expr)
        let key: JQExpr
        var shorthandName: String? = nil
        switch current.kind {
        case .identifier(let n):
            pos += 1
            key = .literal(.string(n))
            shorthandName = n
        case .string(let s):
            pos += 1
            key = .literal(.string(s))
            shorthandName = s
        case .lparen:
            pos += 1
            key = try parsePipe()
            try expect(.rparen, "expected ')' after object key expression")
        default:
            throw JQParseError(message: "expected object key", column: current.column)
        }

        if match(.colon) {
            let value = try parseObjectValue()
            return JQObjectEntry(key: key, value: value)
        }

        // Shorthand `{foo}` == `{foo: .foo}`.
        guard let name = shorthandName else {
            throw JQParseError(message: "expected ':' after object key", column: current.column)
        }
        return JQObjectEntry(key: key,
                             value: .field(base: .identity, name: name, optional: false))
    }

    /// Object member values allow pipes but not the comma operator (which
    /// separates members): objVal := or ('|' or)*
    private func parseObjectValue() throws -> JQExpr {
        var lhs = try parseOr()
        while match(.pipe) {
            let rhs = try parseOr()
            lhs = .pipe(lhs, rhs)
        }
        return lhs
    }
}
