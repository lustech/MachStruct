import Foundation
import Yams

// MARK: - YAMLSourcePatcher

/// Saves an edited YAML document by rewriting only the tokens that changed.
///
/// `YAMLDocumentSerializer` regenerates the file from the tree, which loses
/// everything the tree doesn't hold: comments, anchors, quoting and blank
/// lines. When the edits are value changes and key renames,
/// this instead re-parses the original text, pairs it with the edited tree,
/// and replaces each changed scalar in place.
///
/// Yams reports only where a node *starts*, so each token's extent is
/// reconstructed and checked against the original value; the patched text is
/// then re-parsed and must match the edited tree exactly. Anything it can't
/// do safely — inserted, deleted or moved nodes, block scalars, a change that
/// would also alter an alias — returns `nil`, and the caller falls back to
/// the serializer.
public enum YAMLSourcePatcher {

    /// The original text with the edits applied, or `nil` when they can't be
    /// expressed as in-place replacements.
    public static func patch(source: String, edited index: NodeIndex) -> String? {
        guard let root = index.root,
              let original = try? Yams.compose(yaml: source) else { return nil }

        let text = SourceText(source)
        var patches: [Patch] = []
        guard collect(original, root, in: index, text: text, into: &patches) else { return nil }
        if patches.isEmpty { return source }

        // Apply back to front so earlier offsets stay valid. An anchored node
        // reached through an alias yields the same range twice.
        patches.sort { $0.range.lowerBound > $1.range.lowerBound }
        var bytes = text.bytes
        var previous: Patch?
        for patch in patches {
            if let previous {
                if patch.range == previous.range {
                    guard patch.text == previous.text else { return nil }
                    continue
                }
                guard patch.range.upperBound <= previous.range.lowerBound else { return nil }
            }
            bytes.replaceSubrange(patch.range, with: Array(patch.text.utf8))
            previous = patch
        }

        let patched = String(decoding: bytes, as: UTF8.self)
        guard let reparsed = try? Yams.compose(yaml: patched) else { return nil }
        var remaining: [Patch] = []
        guard collect(reparsed, root, in: index, text: SourceText(patched), into: &remaining),
              remaining.isEmpty else { return nil }
        return patched
    }

    // MARK: - Pairing the source with the edited tree

    private struct Patch {
        let range: Range<Int>
        let text: String
    }

    private static let parser = YAMLParser()

    /// Walk `node` (original) and `edited` together, appending a patch for
    /// every scalar or key that differs. `false` when the shapes differ or a
    /// changed token can't be located.
    private static func collect(_ node: Yams.Node, _ edited: DocumentNode,
                                in index: NodeIndex, text: SourceText,
                                into patches: inout [Patch]) -> Bool {
        let children = index.children(of: edited.id)
        switch node {
        case .mapping(let mapping):
            guard edited.type == .object, children.count == mapping.count else { return false }
            for ((keyNode, valueNode), kv) in zip(mapping, children) {
                guard kv.type == .keyValue, let key = kv.key,
                      let value = index.children(of: kv.id).first else { return false }
                if key != parser.keyText(keyNode) {
                    guard case .scalar(let scalar) = keyNode,
                          let range = text.range(of: scalar) else { return false }
                    patches.append(Patch(range: range,
                                         text: YAMLDocumentSerializer.quoteKeyIfNeeded(key)))
                }
                guard collect(valueNode, value, in: index, text: text, into: &patches) else { return false }
            }
            return true

        case .sequence(let sequence):
            guard edited.type == .array, children.count == sequence.count else { return false }
            for (item, child) in zip(sequence, children) {
                guard collect(item, child, in: index, text: text, into: &patches) else { return false }
            }
            return true

        case .scalar(let scalar):
            guard edited.type == .scalar, case .scalar(let value) = edited.value else { return false }
            if value == parser.inferType(scalar) { return true }
            guard let range = text.range(of: scalar) else { return false }
            patches.append(Patch(range: range, text: literal(value, style: scalar.style)))
            return true

        case .alias:
            return false
        }
    }

    /// `value` written the way the original token was quoted, where possible.
    private static func literal(_ value: ScalarValue, style: Node.Scalar.Style) -> String {
        guard case .string(let s) = value else {
            return YAMLDocumentSerializer.yamlScalarLiteral(value)
        }
        switch style {
        case .doubleQuoted: return YAMLDocumentSerializer.doubleQuote(s)
        case .singleQuoted where !s.contains("\n") && !s.contains("\r"):
            return YAMLDocumentSerializer.singleQuote(s)
        default: return YAMLDocumentSerializer.quoteValueIfNeeded(s)
        }
    }
}

// MARK: - Locating tokens

/// The source as UTF-8 bytes, with libyaml marks (1-based line, column in
/// Unicode scalars) mapped to byte offsets.
private struct SourceText {
    let bytes: [UInt8]
    private let lineStarts: [Int]

    init(_ source: String) {
        bytes = Array(source.utf8)
        var starts = [0]
        var i = 0
        while i < bytes.count {
            // libyaml breaks lines at LF, CR and CRLF.
            if bytes[i] == 0x0A || (bytes[i] == 0x0D && (i + 1 == bytes.count || bytes[i + 1] != 0x0A)) {
                starts.append(i + 1)
            }
            i += 1
        }
        lineStarts = starts
    }

    /// Byte range of the scalar's token, or `nil` unless it can be pinned down
    /// exactly. Block scalars and multi-line flow scalars aren't attempted.
    func range(of scalar: Node.Scalar) -> Range<Int>? {
        guard let mark = scalar.mark, var pos = offset(of: mark) else { return nil }
        // The mark sits on the node's properties (`&anchor`, `!tag`), if any.
        while pos < bytes.count, bytes[pos] == UInt8(ascii: "&") || bytes[pos] == UInt8(ascii: "!") {
            while pos < bytes.count, !isBlank(bytes[pos]) { pos += 1 }
            while pos < bytes.count, bytes[pos] == UInt8(ascii: " ") || bytes[pos] == UInt8(ascii: "\t") {
                pos += 1
            }
        }

        switch scalar.style {
        case .plain, .any:
            return match(Array(scalar.string.utf8), at: pos)
        case .singleQuoted:
            let token = "'" + scalar.string.replacingOccurrences(of: "'", with: "''") + "'"
            return match(Array(token.utf8), at: pos)
        case .doubleQuoted:
            return doubleQuotedRange(at: pos, matching: scalar.string)
        case .literal, .folded:
            return nil
        }
    }

    private func offset(of mark: Mark) -> Int? {
        guard mark.line >= 1, mark.line <= lineStarts.count else { return nil }
        var pos = lineStarts[mark.line - 1]
        for _ in 1..<max(mark.column, 1) {
            guard pos < bytes.count else { return nil }
            pos += utf8Length(bytes[pos])
        }
        return pos
    }

    /// `token` at `pos`, if that is exactly what the source holds there.
    private func match(_ token: [UInt8], at pos: Int) -> Range<Int>? {
        guard !token.isEmpty, pos + token.count <= bytes.count,
              bytes[pos..<pos + token.count].elementsEqual(token) else { return nil }
        return pos..<pos + token.count
    }

    /// The `"…"` token at `pos`, on one line, confirmed by parsing it alone.
    private func doubleQuotedRange(at pos: Int, matching value: String) -> Range<Int>? {
        guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else { return nil }
        var i = pos + 1
        while i < bytes.count {
            switch bytes[i] {
            case UInt8(ascii: "\\"): i += 2; continue
            case 0x0A, 0x0D: return nil
            case UInt8(ascii: "\""):
                let range = pos..<i + 1
                let token = String(decoding: bytes[range], as: UTF8.self)
                guard case .scalar(let parsed)? = try? Yams.compose(yaml: token),
                      parsed.string == value else { return nil }
                return range
            default: i += 1
            }
        }
        return nil
    }

    private func isBlank(_ b: UInt8) -> Bool {
        b == UInt8(ascii: " ") || b == UInt8(ascii: "\t") || b == 0x0A || b == 0x0D
    }

    private func utf8Length(_ lead: UInt8) -> Int {
        switch lead {
        case 0xF0...: return 4
        case 0xE0...: return 3
        case 0xC0...: return 2
        default: return 1
        }
    }
}
