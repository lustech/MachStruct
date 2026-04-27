import Foundation

// MARK: - JSONAutoFixer

/// Best-effort recovery of common non-strict-JSON inputs into valid JSON.
///
/// Handles the everyday "looks like JSON but isn't quite" mistakes that show
/// up when users paste from JS source files, config files, or copy from
/// developer tools:
///
/// - Trailing commas:        `[1, 2,]`              → `[1, 2]`
/// - Single-quoted strings:  `{'a': 'hi'}`          → `{"a": "hi"}`
/// - Unquoted object keys:   `{a: 1}`               → `{"a": 1}`
/// - Line comments:          `{"a":1} // comment`   → `{"a":1}`
/// - Block comments:         `/* note */ {"a":1}`   → `{"a":1}`
/// - Stray semicolons:       `{"a":1};`             → `{"a":1}`
///
/// The fixer runs a single character-level pass with no parsing — it only
/// rewrites tokens it's confident about and tracks the kinds of fixes
/// applied so the UI can summarise them.
public enum JSONAutoFixer {

    /// The kinds of edits the fixer can apply.
    public enum Fix: String, Sendable, Hashable, CaseIterable {
        case trailingComma
        case singleQuotedString
        case unquotedKey
        case lineComment
        case blockComment
        case straySemicolon

        public var summary: String {
            switch self {
            case .trailingComma:       return "Removed trailing commas"
            case .singleQuotedString:  return "Converted single-quoted strings to double-quoted"
            case .unquotedKey:         return "Quoted unquoted object keys"
            case .lineComment:         return "Stripped // line comments"
            case .blockComment:        return "Stripped /* block */ comments"
            case .straySemicolon:      return "Removed stray semicolons"
            }
        }
    }

    /// Result of a fix pass.
    public struct Result: Sendable {
        public let fixed: Data
        public let fixesApplied: Set<Fix>

        public var didChange: Bool { !fixesApplied.isEmpty }
    }

    // MARK: - Entry point

    /// Apply all known fixes to `data`. Always returns successfully — if no
    /// fixes match, `Result.fixed` equals the input bytes.
    public static func fix(_ data: Data) -> Result {
        guard let input = String(data: data, encoding: .utf8) else {
            return Result(fixed: data, fixesApplied: [])
        }
        let (fixed, fixes) = rewrite(input)
        return Result(fixed: Data(fixed.utf8), fixesApplied: fixes)
    }

    // MARK: - Core rewrite

    /// Single-pass character walker.  Tracks whether we're inside a string,
    /// inside a comment, or in normal JSON, and emits the appropriate
    /// substitutions for each.
    private static func rewrite(_ input: String) -> (String, Set<Fix>) {
        var output = ""
        output.reserveCapacity(input.count)
        var fixes = Set<Fix>()

        let chars = Array(input)
        var i = 0
        let n = chars.count

        // Track the last non-whitespace character we emitted so we can detect
        // "after `{` or `,` (object key context)" for unquoted-key fixes.
        var lastNonWS: Character = "\0"

        while i < n {
            let c = chars[i]

            // --- Comments ---
            if c == "/", i + 1 < n {
                let next = chars[i + 1]
                if next == "/" {
                    // Line comment — skip to end of line (preserve the newline).
                    fixes.insert(.lineComment)
                    i += 2
                    while i < n, chars[i] != "\n" { i += 1 }
                    continue
                }
                if next == "*" {
                    // Block comment — skip to closing */.
                    fixes.insert(.blockComment)
                    i += 2
                    while i + 1 < n, !(chars[i] == "*" && chars[i + 1] == "/") {
                        i += 1
                    }
                    i = min(i + 2, n)
                    continue
                }
            }

            // --- Strings ---
            if c == "\"" {
                // Standard double-quoted JSON string — pass through verbatim.
                output.append(c)
                i += 1
                while i < n {
                    let s = chars[i]
                    output.append(s)
                    if s == "\\", i + 1 < n {
                        output.append(chars[i + 1])
                        i += 2
                        continue
                    }
                    if s == "\"" { i += 1; break }
                    i += 1
                }
                lastNonWS = "\""
                continue
            }

            if c == "'" {
                // Single-quoted string — convert to a double-quoted one,
                // re-escaping any embedded " characters.
                fixes.insert(.singleQuotedString)
                output.append("\"")
                i += 1
                while i < n {
                    let s = chars[i]
                    if s == "\\", i + 1 < n {
                        let nxt = chars[i + 1]
                        // \' inside a single-quoted string maps to a literal '.
                        // In double-quoted JSON ' doesn't need escaping.
                        if nxt == "'" {
                            output.append("'")
                        } else {
                            output.append(s)
                            output.append(nxt)
                        }
                        i += 2
                        continue
                    }
                    if s == "'" { i += 1; break }
                    if s == "\"" { output.append("\\\""); i += 1; continue }
                    output.append(s)
                    i += 1
                }
                output.append("\"")
                lastNonWS = "\""
                continue
            }

            // --- Unquoted key: identifier followed by ":" after `{` or `,` ---
            if c.isLetter || c == "_" || c == "$" {
                if lastNonWS == "{" || lastNonWS == "," {
                    var j = i
                    while j < n, isIdentChar(chars[j]) { j += 1 }
                    var k = j
                    while k < n, chars[k].isWhitespace { k += 1 }
                    if k < n, chars[k] == ":" {
                        let ident = String(chars[i..<j])
                        // Don't quote the literals true/false/null when they
                        // happen to appear in a key position (extremely unlikely
                        // but harmless to be safe).
                        if !["true", "false", "null"].contains(ident) {
                            fixes.insert(.unquotedKey)
                            output.append("\"")
                            output.append(ident)
                            output.append("\"")
                            lastNonWS = "\""
                            i = j
                            continue
                        }
                    }
                }
            }

            // --- Trailing comma: `,` followed by whitespace then `]` or `}` ---
            if c == "," {
                var j = i + 1
                while j < n, chars[j].isWhitespace { j += 1 }
                if j < n, chars[j] == "]" || chars[j] == "}" {
                    fixes.insert(.trailingComma)
                    // Skip the comma; continue from the same `i + 1` so any
                    // intervening whitespace is preserved.
                    i += 1
                    continue
                }
            }

            // --- Stray semicolon (e.g. `'use strict';` after conversion) ---
            if c == ";" {
                fixes.insert(.straySemicolon)
                i += 1
                continue
            }

            output.append(c)
            if !c.isWhitespace { lastNonWS = c }
            i += 1
        }

        return (output, fixes)
    }

    // MARK: - Helpers

    private static func isIdentChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "$"
    }
}
