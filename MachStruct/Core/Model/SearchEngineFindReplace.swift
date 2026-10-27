import Foundation

// MARK: - Find & Replace (Data Workbench — v2.0)

public extension SearchEngine {

    // MARK: Options

    /// Configuration for a find-&-replace pass.
    struct FindOptions: Sendable {
        public enum Scope: Sendable { case keys, values, both }

        public var useRegex: Bool
        public var caseSensitive: Bool
        public var scope: Scope

        public init(useRegex: Bool, caseSensitive: Bool, scope: Scope) {
            self.useRegex = useRegex
            self.caseSensitive = caseSensitive
            self.scope = scope
        }

        var matchesKeys: Bool   { scope == .keys || scope == .both }
        var matchesValues: Bool { scope == .values || scope == .both }
    }

    /// A find hit, carrying both the row to highlight and the node to edit.
    struct FindMatch: Sendable {
        /// The tree row to highlight/scroll to.
        public let rowNodeID: NodeID
        /// The node actually holding the matched text (the keyValue for a key
        /// match, the scalar for a value match) — the node a replacement edits.
        public let nodeID: NodeID
        public let field: SearchMatch.Field
        public let originalText: String
    }

    // MARK: Find

    /// All nodes whose key or value matches `pattern`, in document order.
    static func matches(pattern: String,
                        options: FindOptions,
                        in index: NodeIndex) -> [FindMatch] {
        guard !pattern.isEmpty, let matcher = TextMatcher(pattern: pattern, options: options) else {
            return []
        }

        var results: [FindMatch] = []
        var stack: [NodeID] = [index.rootID]
        // DFS pre-order over childIDs (document order).
        var ordered: [NodeID] = []
        while let id = stack.popLast() {
            ordered.append(id)
            if let node = index.node(for: id) {
                stack.append(contentsOf: node.childIDs.reversed())
            }
        }

        for id in ordered {
            guard let node = index.node(for: id) else { continue }

            if options.matchesKeys, node.type == .keyValue,
               let key = node.key, matcher.matches(key) {
                results.append(FindMatch(rowNodeID: id, nodeID: id,
                                         field: .key, originalText: key))
            }

            if options.matchesValues, node.type == .scalar,
               case .scalar(let sv) = node.value {
                let text = sv.searchableText
                if matcher.matches(text) {
                    let rowID = displayRow(for: node, in: index)
                    results.append(FindMatch(rowNodeID: rowID, nodeID: id,
                                             field: .value, originalText: text))
                }
            }
        }
        return results
    }

    /// How many matches `matches(pattern:options:in:)` would find in a large
    /// document as edited, in one pass over it: nodes in `index` are read
    /// from there and the rest built from `source` as they are reached,
    /// without keeping them.
    static func matchCount(pattern: String,
                           options: FindOptions,
                           in index: NodeIndex,
                           source: any DocumentSource) -> Int {
        guard !pattern.isEmpty, let matcher = TextMatcher(pattern: pattern, options: options) else {
            return 0
        }
        var count = 0
        source.traverse(overlaying: index) { node, _ in
            if options.matchesKeys, node.type == .keyValue,
               let key = node.key, matcher.matches(key) {
                count += 1
            }
            if options.matchesValues, node.type == .scalar,
               case .scalar(let sv) = node.value, matcher.matches(sv.searchableText) {
                count += 1
            }
            return true
        }
        return count
    }

    // MARK: Replace

    /// Replaces every match of `pattern` with `replacement` across the document,
    /// returning a single undoable `EditTransaction` (or `nil` if nothing
    /// matched).
    ///
    /// Value replacements re-infer the scalar type of the result (e.g. replacing
    /// inside the integer `30` yields an integer), except that an original
    /// string value always stays a string.
    static func replaceAll(pattern: String,
                           replacement: String,
                           options: FindOptions,
                           in index: NodeIndex) -> EditTransaction? {
        guard let matcher = TextMatcher(pattern: pattern, options: options) else { return nil }

        var updated: [NodeID: DocumentNode] = [:]

        for match in matches(pattern: pattern, options: options, in: index) {
            guard var node = index.node(for: match.nodeID) else { continue }
            let newText = matcher.replacingMatches(in: match.originalText, with: replacement)
            guard newText != match.originalText else { continue }

            switch match.field {
            case .key:
                node.key = newText
            case .value:
                if case .scalar(.string) = node.value {
                    node.value = .scalar(.string(newText))
                } else {
                    node.value = .scalar(parseScalarValue(newText))
                }
            }
            updated[match.nodeID] = node
        }

        guard !updated.isEmpty else { return nil }
        return EditTransaction.batchUpdate(updated, description: "Replace All", in: index)
    }

    // MARK: Private

    /// Resolve a scalar node to the row that displays it (inline scalars are
    /// shown on their `keyValue` parent's row).
    private static func displayRow(for node: DocumentNode, in index: NodeIndex) -> NodeID {
        if node.type == .scalar, let pid = node.parentID,
           index.node(for: pid)?.type == .keyValue {
            return pid
        }
        return node.id
    }
}

// MARK: - TextMatcher

/// Wraps either a literal or regex matcher with consistent case handling.
struct TextMatcher {
    private let regex: NSRegularExpression?
    private let literal: String?
    private let caseSensitive: Bool
    /// A printable-ASCII literal's bytes, lowercased unless case-sensitive.
    private let asciiLiteral: [UInt8]?

    init?(pattern: String, options: SearchEngine.FindOptions) {
        self.caseSensitive = options.caseSensitive
        if options.useRegex {
            var opts: NSRegularExpression.Options = []
            if !options.caseSensitive { opts.insert(.caseInsensitive) }
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else {
                return nil   // invalid regex
            }
            self.regex = re
            self.literal = nil
            self.asciiLiteral = nil
        } else {
            self.regex = nil
            self.literal = pattern
            let bytes = Array(pattern.utf8)
            self.asciiLiteral = !bytes.isEmpty && bytes.allSatisfy(Self.isPrintableASCII)
                ? (options.caseSensitive ? bytes : bytes.map(Self.lowercased)) : nil
        }
    }

    func matches(_ text: String) -> Bool {
        if let regex {
            let range = NSRange(text.startIndex..., in: text)
            return regex.firstMatch(in: text, range: range) != nil
        }
        guard let literal else { return false }
        if let asciiLiteral, let found = Self.findASCII(asciiLiteral, in: text,
                                                       caseSensitive: caseSensitive) {
            return found
        }
        let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        return text.range(of: literal, options: opts) != nil
    }

    // MARK: Printable ASCII

    // Between printable-ASCII strings, Foundation's comparison is plain byte
    // comparison (case-insensitive: ASCII case folding), so a large file's
    // match count needn't go through it for each value. Anything else —
    // control characters, which can join into one grapheme, or any non-ASCII
    // text, which has Unicode folding — still does.

    private static func isPrintableASCII(_ b: UInt8) -> Bool { b >= 0x20 && b <= 0x7E }

    private static func lowercased(_ b: UInt8) -> UInt8 {
        b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z") ? b | 0x20 : b
    }

    /// Whether `text` contains `needle`, or `nil` when `text` isn't all
    /// printable ASCII and Foundation must decide.
    private static func findASCII(_ needle: [UInt8], in text: String,
                                  caseSensitive: Bool) -> Bool? {
        var text = text
        return text.withUTF8 { hay -> Bool? in
            var found = false
            let n = needle.count
            for i in hay.indices {
                let b = hay[i]
                guard isPrintableASCII(b) else { return nil }
                guard !found, i + n <= hay.count else { continue }
                var j = 0
                while j < n {
                    let h = hay[i + j]
                    if (caseSensitive ? h : lowercased(h)) != needle[j] { break }
                    j += 1
                }
                if j == n { found = true }
            }
            return found
        }
    }

    func replacingMatches(in text: String, with replacement: String) -> String {
        if let regex {
            let range = NSRange(text.startIndex..., in: text)
            return regex.stringByReplacingMatches(in: text, range: range,
                                                  withTemplate: replacement)
        }
        guard let literal else { return text }
        let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        return text.replacingOccurrences(of: literal, with: replacement, options: opts)
    }
}
