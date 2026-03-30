import Foundation

// MARK: - YAMLDocumentSerializer

/// Serializes a `NodeIndex` to YAML text.
///
/// Produces canonical block-style YAML 1.2 output — no flow sequences/mappings
/// except for empty containers (`[]`, `{}`).  All string scalars are quoted
/// only when necessary; numbers and booleans use plain style.
///
/// **Unparsed nodes** (from simdjson large-file path) are emitted as `null`
/// since the raw bytes cannot be re-interpreted without the original format
/// context.
public struct YAMLDocumentSerializer {

    private let index: NodeIndex

    public init(index: NodeIndex) {
        self.index = index
    }

    // MARK: - Public API

    /// Serialize the entire document to YAML bytes (UTF-8).
    public func serialize() throws -> Data {
        guard let root = index.root else {
            throw YAMLSerializerError.emptyDocument
        }
        var out = "---\n"
        appendNode(root, indent: 0, to: &out)
        return Data(out.utf8)
    }

    // MARK: - Recursive node rendering

    /// Appends the full block representation of `node` at `indent` spaces.
    private func appendNode(_ node: DocumentNode, indent: Int, to out: inout String) {
        switch node.type {
        case .object:
            let kvChildren = index.children(of: node.id)
            if kvChildren.isEmpty {
                out += String(repeating: " ", count: indent) + "{}\n"
                return
            }
            for kv in kvChildren {
                appendKeyValue(kv, indent: indent, to: &out)
            }

        case .array:
            let items = index.children(of: node.id)
            if items.isEmpty {
                out += String(repeating: " ", count: indent) + "[]\n"
                return
            }
            for item in items {
                out += String(repeating: " ", count: indent) + "-"
                appendInlineOrBlock(item, indent: indent + 2, to: &out)
            }

        case .keyValue:
            // keyValue should be handled via appendKeyValue; guard defensively.
            appendKeyValue(node, indent: indent, to: &out)

        case .scalar:
            out += String(repeating: " ", count: indent) + scalarText(node) + "\n"
        }
    }

    /// Outputs a `keyValue` node as `key: value\n` (or `key:\n  block`).
    private func appendKeyValue(_ kv: DocumentNode, indent: Int, to out: inout String) {
        guard let key = kv.key else { return }
        let spaces = String(repeating: " ", count: indent)
        out += spaces + quoteKeyIfNeeded(key) + ":"
        let valueChildren = index.children(of: kv.id)
        if let valueNode = valueChildren.first {
            appendInlineOrBlock(valueNode, indent: indent + 2, to: &out)
        } else {
            out += " null\n"
        }
    }

    /// For scalars: appends ` value\n` (inline after `key:` or `-`).
    /// For containers: appends `\n` then the block at `indent`.
    private func appendInlineOrBlock(_ node: DocumentNode, indent: Int, to out: inout String) {
        switch node.type {
        case .scalar:
            out += " \(scalarText(node))\n"

        case .object:
            let kvChildren = index.children(of: node.id)
            if kvChildren.isEmpty {
                out += " {}\n"
            } else {
                out += "\n"
                for kv in kvChildren {
                    appendKeyValue(kv, indent: indent, to: &out)
                }
            }

        case .array:
            let items = index.children(of: node.id)
            if items.isEmpty {
                out += " []\n"
            } else {
                out += "\n"
                for item in items {
                    out += String(repeating: " ", count: indent) + "-"
                    appendInlineOrBlock(item, indent: indent + 2, to: &out)
                }
            }

        case .keyValue:
            // Defensive: treat as a block.
            out += "\n"
            appendKeyValue(node, indent: indent, to: &out)
        }
    }

    // MARK: - Scalar formatting

    private func scalarText(_ node: DocumentNode) -> String {
        switch node.value {
        case .scalar(let sv):
            return yamlScalarLiteral(sv)
        case .unparsed:
            return "null"
        case .container, .error:
            return "null"
        }
    }

    private func yamlScalarLiteral(_ sv: ScalarValue) -> String {
        switch sv {
        case .string(let s):  return quoteValueIfNeeded(s)
        case .integer(let i): return String(i)
        case .float(let f):   return yamlDouble(f)
        case .boolean(let b): return b ? "true" : "false"
        case .null:           return "null"
        }
    }

    private func yamlDouble(_ value: Double) -> String {
        if value.isNaN      { return ".nan" }
        if value.isInfinite { return value > 0 ? ".inf" : "-.inf" }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.1f", value)
        }
        return String(value)
    }

    // MARK: - Quoting helpers

    /// YAML keywords that must be quoted when used as string scalars.
    private static let reservedWords: Set<String> = [
        "true", "false", "yes", "no", "on", "off", "null", "~",
        "True", "False", "Yes", "No", "On", "Off", "Null",
        "TRUE", "FALSE", "YES", "NO", "ON", "OFF", "NULL"
    ]

    /// Quote a scalar string value when YAML would misinterpret it.
    private func quoteValueIfNeeded(_ s: String) -> String {
        guard !s.isEmpty else { return "''" }

        // Reserved words that would be parsed as non-string
        if Self.reservedWords.contains(s) {
            return singleQuote(s)
        }

        // Strings that look like YAML numbers
        if Int64(s) != nil || Double(s) != nil { return singleQuote(s) }

        // Strings with embedded newlines need double-quoting with escape sequences
        if s.contains("\n") || s.contains("\r") || s.contains("\0") {
            return doubleQuote(s)
        }

        // Characters / prefixes that confuse the YAML scanner
        let firstChar = s.unicodeScalars.first
        let startsSpecial = firstChar.map { c in
            "-:?|>!&*#{}[],%@`\"'".unicodeScalars.contains(c)
        } ?? false

        if startsSpecial
            || s.hasPrefix(" ") || s.hasSuffix(" ")
            || s.hasPrefix(".")
            || s.contains(": ")
            || s.hasSuffix(":")
            || s.contains(" #") {
            return singleQuote(s)
        }

        return s
    }

    /// Quote a mapping key when it would confuse YAML.
    private func quoteKeyIfNeeded(_ key: String) -> String {
        guard !key.isEmpty else { return "''" }
        if Self.reservedWords.contains(key) { return singleQuote(key) }
        // Only quote keys that *look* like bare numbers (start with a digit or
        // `-` followed by a digit).  Avoid using Double() here because Swift's
        // parser accepts "inf" / "nan" as Double.infinity / nan, which would
        // incorrectly quote legitimate word-keys like "inf".
        if keyLooksNumeric(key) { return singleQuote(key) }

        let needsQuote = key.contains(":")  || key.contains("#")
                      || key.hasPrefix("-") || key.hasPrefix("?")
                      || key.hasPrefix(" ") || key.hasSuffix(" ")
                      || key.contains("\"") || key.contains("'")
                      || key.contains("\n")
        return needsQuote ? singleQuote(key) : key
    }

    /// Returns `true` when `key` is composed only of numeric characters
    /// (digits, `.`, `e`/`E`, `+`/`-`) and starts with a digit or `-digit`.
    private func keyLooksNumeric(_ key: String) -> Bool {
        var idx = key.startIndex
        if key[idx] == "-" {
            idx = key.index(after: idx)
            guard idx < key.endIndex else { return false }
        }
        guard key[idx].isNumber else { return false }
        return key[idx...].allSatisfy { $0.isNumber || $0 == "." || $0 == "e" || $0 == "E" || $0 == "+" || $0 == "-" }
    }

    /// Wrap in single quotes; escape interior single quotes by doubling them.
    private func singleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Wrap in double quotes with YAML escape sequences.
    private func doubleQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\0", with: "\\0")
        return "\"" + escaped + "\""
    }
}

// MARK: - Errors

public enum YAMLSerializerError: Error, Sendable {
    case emptyDocument
}
