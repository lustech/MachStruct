import Foundation

// MARK: - JQToken

/// A lexical token plus its 0-based start column (for error reporting).
struct JQToken: Equatable {
    enum Kind: Equatable {
        case dot
        case identifier(String)   // foo, length, select, true, false, null, and, or, not
        case string(String)       // decoded contents of a "…" literal
        case number(JQValue)      // .int or .double literal
        case lbracket, rbracket
        case lbrace, rbrace
        case lparen, rparen
        case pipe, comma, colon, semicolon, question
        case op(JQBinaryOp)
        case eof
    }

    let kind: Kind
    let column: Int
}

// MARK: - JQLexer

/// Converts a jq query string into a flat token stream.
///
/// Stateless from the caller's perspective: `tokenize(_:)` either returns all
/// tokens (terminated by `.eof`) or throws a `JQParseError` for malformed input
/// (e.g. an unterminated string literal).
enum JQLexer {

    static func tokenize(_ source: String) throws -> [JQToken] {
        let chars = Array(source)
        var i = 0
        var tokens: [JQToken] = []

        func peek(_ offset: Int = 0) -> Character? {
            let j = i + offset
            return j < chars.count ? chars[j] : nil
        }

        while i < chars.count {
            let c = chars[i]
            let start = i

            // Whitespace.
            if c.isWhitespace { i += 1; continue }

            switch c {
            case ".":
                tokens.append(JQToken(kind: .dot, column: start)); i += 1
            case "[":
                tokens.append(JQToken(kind: .lbracket, column: start)); i += 1
            case "]":
                tokens.append(JQToken(kind: .rbracket, column: start)); i += 1
            case "{":
                tokens.append(JQToken(kind: .lbrace, column: start)); i += 1
            case "}":
                tokens.append(JQToken(kind: .rbrace, column: start)); i += 1
            case "(":
                tokens.append(JQToken(kind: .lparen, column: start)); i += 1
            case ")":
                tokens.append(JQToken(kind: .rparen, column: start)); i += 1
            case "|":
                tokens.append(JQToken(kind: .pipe, column: start)); i += 1
            case ",":
                tokens.append(JQToken(kind: .comma, column: start)); i += 1
            case ":":
                tokens.append(JQToken(kind: .colon, column: start)); i += 1
            case ";":
                tokens.append(JQToken(kind: .semicolon, column: start)); i += 1
            case "?":
                tokens.append(JQToken(kind: .question, column: start)); i += 1

            case "=":
                guard peek(1) == "=" else {
                    throw JQParseError(message: "expected '==' (assignment is not supported)", column: start)
                }
                tokens.append(JQToken(kind: .op(.eq), column: start)); i += 2
            case "!":
                guard peek(1) == "=" else {
                    throw JQParseError(message: "expected '!='", column: start)
                }
                tokens.append(JQToken(kind: .op(.neq), column: start)); i += 2
            case "<":
                if peek(1) == "=" { tokens.append(JQToken(kind: .op(.le), column: start)); i += 2 }
                else { tokens.append(JQToken(kind: .op(.lt), column: start)); i += 1 }
            case ">":
                if peek(1) == "=" { tokens.append(JQToken(kind: .op(.ge), column: start)); i += 2 }
                else { tokens.append(JQToken(kind: .op(.gt), column: start)); i += 1 }
            case "+":
                tokens.append(JQToken(kind: .op(.add), column: start)); i += 1
            case "-":
                tokens.append(JQToken(kind: .op(.sub), column: start)); i += 1
            case "*":
                tokens.append(JQToken(kind: .op(.mul), column: start)); i += 1
            case "/":
                tokens.append(JQToken(kind: .op(.div), column: start)); i += 1

            case "\"":
                let (str, next) = try Self.lexString(chars, from: i)
                tokens.append(JQToken(kind: .string(str), column: start))
                i = next

            default:
                if c.isNumber {
                    let (value, next) = Self.lexNumber(chars, from: i)
                    tokens.append(JQToken(kind: .number(value), column: start))
                    i = next
                } else if c.isLetter || c == "_" {
                    let (name, next) = Self.lexIdentifier(chars, from: i)
                    tokens.append(JQToken(kind: .identifier(name), column: start))
                    i = next
                } else {
                    throw JQParseError(message: "unexpected character '\(c)'", column: start)
                }
            }
        }

        tokens.append(JQToken(kind: .eof, column: chars.count))
        return tokens
    }

    // MARK: - Sub-lexers

    private static func lexString(_ chars: [Character], from start: Int) throws -> (String, Int) {
        var i = start + 1   // skip opening quote
        var out = ""
        while i < chars.count {
            let c = chars[i]
            if c == "\"" { return (out, i + 1) }
            if c == "\\" {
                guard i + 1 < chars.count else {
                    throw JQParseError(message: "unterminated escape in string", column: start)
                }
                let e = chars[i + 1]
                switch e {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/":  out.append("/")
                case "n":  out.append("\n")
                case "t":  out.append("\t")
                case "r":  out.append("\r")
                default:
                    throw JQParseError(message: "invalid escape '\\\(e)'", column: i)
                }
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        throw JQParseError(message: "unterminated string literal", column: start)
    }

    private static func lexNumber(_ chars: [Character], from start: Int) -> (JQValue, Int) {
        var i = start
        var isDouble = false
        while i < chars.count {
            let c = chars[i]
            if c.isNumber { i += 1 }
            else if c == "." && !isDouble { isDouble = true; i += 1 }
            else if (c == "e" || c == "E") { isDouble = true; i += 1
                if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
            }
            else { break }
        }
        let text = String(chars[start..<i])
        if !isDouble, let n = Int64(text) {
            return (.int(n), i)
        }
        return (.double(Double(text) ?? 0), i)
    }

    private static func lexIdentifier(_ chars: [Character], from start: Int) -> (String, Int) {
        var i = start
        while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
            i += 1
        }
        return (String(chars[start..<i]), i)
    }
}
