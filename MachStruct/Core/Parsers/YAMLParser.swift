import Foundation
import Yams

// MARK: - YAMLParser

/// Event-driven YAML parser built on Yams (libyaml wrapper).
///
/// **Phase 1** — `buildIndex(from:)`:
///   Calls `Yams.compose_all()` to get the raw YAML AST, then recursively walks
///   it to produce a flat `IndexEntry` array in document order. A file with
///   several `---` documents gets a root sequence of the documents.
///
///   Node mapping:
///   - YAML mapping  → `.object`   (key-value pairs become `.keyValue` children)
///   - YAML sequence → `.array`    (items are indexed children `"0"`, `"1"`, …)
///   - YAML scalar   → `.scalar`   (type inferred from tag or string content)
///
///   Anchor names are captured eagerly in `YAMLMetadata.anchor`.
///   Aliases are resolved by Yams before we walk the tree; the resolved node
///   receives a fresh `NodeID` but no alias marker (Phase 4 can add tracking).
///   An unresolved alias, should one ever reach the walker, is indexed as a
///   `*anchor` placeholder scalar rather than dropped.
///
/// **Phase 2** — `parseValue(entry:from:)`:
///   All scalars are parsed eagerly during Phase 1 via `parsedValue`.
///   This method simply returns the stored value — no re-read is needed.
public actor YAMLParser: StructParser {

    public static let supportedExtensions: Set<String> = ["yaml", "yml"]

    public init() {}

    // MARK: - Phase 1

    public func buildIndex(from file: MappedFile) async throws -> StructuralIndex {
        // mmap requires a non-zero file; treat empty files as blank YAML documents.
        guard file.fileSize > 0 else {
            let entry = IndexEntry(id: .generate(), nodeType: .object, depth: 0, parentID: nil)
            return StructuralIndex(entries: [entry])
        }

        let length = UInt32(min(file.fileSize, UInt64(UInt32.max)))
        if let entries = YAMLEventIndexer.entries(file.rawPointer, count: Int(length)) {
            return StructuralIndex(entries: entries)
        }

        // Compose the documents: the events had something the indexer leaves
        // to the composer, such as an alias or an error.
        let data = try file.data(offset: 0, length: length)
        guard let yamlString = String(data: data, encoding: .utf8) else {
            throw YAMLParserError.encodingError
        }

        do {
            return StructuralIndex(entries: try indexEntries(composing: yamlString))
        } catch let error as YamlError {
            throw data.withUnsafeBytes { YAMLParser.parseError(from: error, in: $0) }
        }
    }

    /// The entries of `yaml`, composed and walked.
    nonisolated func indexEntries(composing yaml: String) throws -> [IndexEntry] {
        // A node's anchor is held weakly; its parser holds it, so walk the
        // documents while that is alive (#79).
        try Self.withDocuments(in: yaml) { documents in
            switch documents.count {
            case 0:
                // Whitespace-only content holds no documents.
                return [IndexEntry(id: .generate(), nodeType: .object, depth: 0, parentID: nil)]
            case 1:
                return indexEntries(for: documents[0])
            default:
                return indexEntries(forDocuments: documents)
            }
        }
    }

    /// Every document in `yaml`, in order, including an error in a later one.
    nonisolated static func documents(in yaml: String) throws -> [Yams.Node] {
        try withDocuments(in: yaml) { $0 }
    }

    /// `body` on every document in `yaml`, while their anchors are alive.
    nonisolated static func withDocuments<T>(in yaml: String,
                                             _ body: ([Yams.Node]) throws -> T) throws -> T {
        var stream = try Yams.compose_all(yaml: yaml)
        var documents: [Yams.Node] = []
        while let document = stream.next() { documents.append(document) }
        if let error = stream.error { throw error }
        return try withExtendedLifetime(stream) { try body(documents) }
    }

    /// Flatten a composed Yams tree into `IndexEntry` values in pre-order.
    nonisolated func indexEntries(for root: Yams.Node) -> [IndexEntry] {
        var entries: [IndexEntry] = []
        walkNode(root, parentID: nil, depth: 0, key: nil, into: &entries)
        return entries
    }

    /// Several documents, indexed as the items of a root sequence marked
    /// `isDocumentStream` so they save back as separate documents.
    nonisolated func indexEntries(forDocuments documents: [Yams.Node]) -> [IndexEntry] {
        let rootID = NodeID.generate()
        var entries = [IndexEntry(
            id: rootID,
            nodeType: .array,
            depth: 0,
            parentID: nil,
            childCount: UInt32(documents.count),
            metadata: .yaml(YAMLMetadata(isDocumentStream: true))
        )]
        for (i, document) in documents.enumerated() {
            walkNode(document, parentID: rootID, depth: 1, key: String(i), into: &entries)
        }
        return entries
    }

    // MARK: - Progressive streaming

    public nonisolated func parseProgressively(file: MappedFile) -> AsyncStream<ParseProgress> {
        ParseProgress.stream { try await YAMLParser().buildIndex(from: file) }
    }

    // MARK: - Phase 2

    public nonisolated func parseValue(entry: IndexEntry, from file: MappedFile) throws -> NodeValue {
        if let sv = entry.parsedValue { return .scalar(sv) }
        switch entry.nodeType {
        case .object:  return .container(childCount: Int(entry.childCount))
        case .array:   return .container(childCount: Int(entry.childCount))
        case .keyValue: return .unparsed
        case .scalar:   return .unparsed
        }
    }

    // MARK: - Serialize

    public nonisolated func serialize(value: NodeValue) throws -> Data {
        switch value {
        case .scalar(let sv):
            return Data(yamlLiteral(for: sv).utf8)
        case .container:
            throw YAMLParserError.cannotSerializeContainer
        case .unparsed, .error:
            throw YAMLParserError.noValueToSerialize
        }
    }

    // MARK: - Validate

    public func validate(file: MappedFile) async throws -> [ValidationIssue] {
        let length = UInt32(min(file.fileSize, UInt64(UInt32.max)))
        let data = try file.data(offset: 0, length: length)
        guard let yamlString = String(data: data, encoding: .utf8) else {
            return [ValidationIssue(severity: .error, message: "File is not valid UTF-8")]
        }
        do {
            _ = try Self.documents(in: yamlString)
            return []
        } catch {
            return [ValidationIssue(severity: .error, message: error.localizedDescription)]
        }
    }
}

// MARK: - Parse errors

extension YAMLParser {

    /// Yams' error, restated as a `ParseError`: libyaml's problem and context
    /// ("did not find expected ',' or ']'" while parsing a flow sequence) at
    /// the problem's position, without "Yams.YamlError error 1".
    static func parseError(from error: YamlError, in source: UnsafeRawBufferPointer) -> ParseError {
        switch error {
        case .scanner(let context, let problem, let mark, _),
             .parser(let context, let problem, let mark, _),
             .composer(let context, let problem, let mark, _):
            // libyaml's context is either a clause ("while parsing a flow
            // sequence") or the first half of the sentence ("expected a
            // single document in the stream" … "but found another document").
            let text: String
            switch context?.text {
            case nil: text = problem
            case let c? where c.hasPrefix("while"): text = "\(problem) \(c)"
            case let c?: text = "\(c) \(problem)"
            }
            return ParseError(problem: text, line: mark.line, column: mark.column, in: source)
        case .reader(let problem, let offset, _, _):
            guard let offset else { return ParseError(problem: problem) }
            return ParseError(problem: problem, byteOffset: offset, in: source)
        case .dataCouldNotBeDecoded:
            return ParseError(problem: "The file isn't valid UTF-8 text")
        default:
            return ParseError(problem: "The file isn't valid YAML")
        }
    }
}

// MARK: - Tree walker

extension YAMLParser {

    /// Recursively walk one Yams `Node` and append `IndexEntry` values in pre-order.
    private nonisolated func walkNode(
        _ node: Yams.Node,
        parentID: NodeID?,
        depth: UInt16,
        key: String?,
        into entries: inout [IndexEntry]
    ) {
        switch node {

        // MARK: Mapping → .object + .keyValue children

        case .mapping(let mapping):
            let nodeID = NodeID.generate()
            entries.append(IndexEntry(
                id: nodeID,
                nodeType: .object,
                depth: depth,
                parentID: parentID,
                childCount: UInt32(mapping.count),
                key: key,
                sharedMetadata: YAMLEventIndexer.metadata(anchor: mapping.anchor?.rawValue,
                                                          tag: nil, style: .plain)
            ))
            for (keyNode, valueNode) in mapping {
                let kvID = NodeID.generate()
                entries.append(IndexEntry(
                    id: kvID,
                    nodeType: .keyValue,
                    depth: depth + 1,
                    parentID: nodeID,
                    childCount: 1,
                    key: keyText(keyNode)
                ))
                walkNode(valueNode, parentID: kvID, depth: depth + 2, key: nil, into: &entries)
            }

        // MARK: Sequence → .array + positional children

        case .sequence(let sequence):
            let nodeID = NodeID.generate()
            entries.append(IndexEntry(
                id: nodeID,
                nodeType: .array,
                depth: depth,
                parentID: parentID,
                childCount: UInt32(sequence.count),
                key: key,
                sharedMetadata: YAMLEventIndexer.metadata(anchor: sequence.anchor?.rawValue,
                                                          tag: nil, style: .plain)
            ))
            for (i, item) in sequence.enumerated() {
                walkNode(item, parentID: nodeID, depth: depth + 1, key: String(i), into: &entries)
            }

        // MARK: Scalar → .scalar (eagerly parsed)

        case .scalar(let scalar):
            let nodeID = NodeID.generate()
            let sv = inferType(scalar)
            let style = mapStyle(scalar.style)
            let customTag = nonStandardTag(scalar.tag)
            entries.append(IndexEntry(
                id: nodeID,
                nodeType: .scalar,
                depth: depth,
                parentID: parentID,
                childCount: 0,
                key: key,
                parsedValue: sv,
                sharedMetadata: YAMLEventIndexer.metadata(anchor: scalar.anchor?.rawValue,
                                                          tag: customTag, style: style)
            ))

        // MARK: Alias → .scalar placeholder
        //
        // compose() resolves aliases before we see the tree, so this is not
        // reached today. If a Yams change ever lets one through, show it as
        // `*anchor` rather than silently dropping the node (#21).

        case .alias(let alias):
            let name = alias.anchor.rawValue
            entries.append(IndexEntry(
                id: NodeID.generate(),
                nodeType: .scalar,
                depth: depth,
                parentID: parentID,
                childCount: 0,
                key: key,
                parsedValue: .string("*\(name)"),
                metadata: .yaml(YAMLMetadata(alias: name, scalarStyle: .plain))
            ))
        }
    }

    /// Display text for a mapping key. Scalar keys use their string; complex
    /// keys (`? [a, b]`) are rendered as flow YAML so the pair is kept rather
    /// than skipped.
    nonisolated func keyText(_ keyNode: Yams.Node) -> String {
        switch keyNode {
        case .scalar(let scalar):
            return scalar.string
        case .sequence(let sequence):
            return "[" + sequence.map(keyText).joined(separator: ", ") + "]"
        case .mapping(let mapping):
            return "{" + mapping.map { "\(keyText($0.key)): \(keyText($0.value))" }
                .joined(separator: ", ") + "}"
        case .alias(let alias):
            return "*\(alias.anchor.rawValue)"
        }
    }

    // MARK: - Scalar type inference

    /// Infer a `ScalarValue` from a Yams scalar node.
    ///
    /// Uses the resolved YAML tag when available, then falls back to heuristic
    /// string matching (same rules as YAML 1.1 implicit resolution).
    nonisolated func inferType(_ scalar: Yams.Node.Scalar) -> ScalarValue {
        Self.inferType(scalar.string, tag: scalar.tag.description,
                       quoted: scalar.style == .singleQuoted || scalar.style == .doubleQuoted)
    }

    /// `inferType` from a scalar's text, its tag as written (empty when it
    /// has none) and whether it was quoted.
    nonisolated static func inferType(_ str: String, tag: String, quoted: Bool) -> ScalarValue {
        // Quoted strings are always strings regardless of content.
        if quoted { return .string(str) }

        // Explicit tag takes priority.
        if tag.hasSuffix(":str")  { return .string(str) }
        if tag.hasSuffix(":null") { return .null }
        if tag.hasSuffix(":bool") { return boolValue(str) }
        if tag.hasSuffix(":int")  { return intValue(str) }
        if tag.hasSuffix(":float") { return floatValue(str) }

        // Implicit resolution. The keywords are five letters at most, and
        // lowercasing a longer string would allocate for nothing.
        if str.isEmpty || str == "~" { return .null }
        if str.utf8.count <= 5 {
            switch str.lowercased() {
            case "null":               return .null
            case "true", "yes", "on":  return .boolean(true)
            case "false", "no", "off": return .boolean(false)
            default: break
            }
        }
        if let i = Int64(str)   { return .integer(i) }
        if let f = Double(str)  { return .float(f) }
        return .string(str)
    }

    nonisolated static func boolValue(_ str: String) -> ScalarValue {
        .boolean(["true", "yes", "on", "1"].contains(str.lowercased()))
    }

    nonisolated static func intValue(_ str: String) -> ScalarValue {
        if str.hasPrefix("0x") || str.hasPrefix("0X") {
            return .integer(Int64(str.dropFirst(2), radix: 16) ?? 0)
        }
        if str.hasPrefix("0o") {
            return .integer(Int64(str.dropFirst(2), radix: 8) ?? 0)
        }
        return .integer(Int64(str) ?? 0)
    }

    nonisolated static func floatValue(_ str: String) -> ScalarValue {
        switch str {
        case ".inf", "+.inf": return .float(.infinity)
        case "-.inf":         return .float(-.infinity)
        case ".nan":          return .float(.nan)
        default:              return .float(Double(str) ?? 0)
        }
    }

    // MARK: - Style mapping

    nonisolated func mapStyle(_ style: Yams.Node.Scalar.Style) -> YAMLScalarStyle {
        switch style {
        case .plain:        return .plain
        case .singleQuoted: return .singleQuoted
        case .doubleQuoted: return .doubleQuoted
        case .literal:      return .literal
        case .folded:       return .folded
        case .any:          return .plain
        @unknown default:   return .plain
        }
    }

    /// Returns the tag string only when it's a custom/explicit tag (not a standard yaml.org tag).
    nonisolated func nonStandardTag(_ tag: Yams.Tag) -> String? {
        Self.nonStandardTag(tag.description)
    }

    nonisolated static func nonStandardTag(_ desc: String) -> String? {
        guard !desc.isEmpty,
              !desc.hasPrefix("tag:yaml.org"),
              desc != "!" else { return nil }
        return desc
    }

    // MARK: - YAML serialization

    /// Produce a YAML literal for a scalar value, quoting when necessary.
    nonisolated func yamlLiteral(for sv: ScalarValue) -> String {
        switch sv {
        case .string(let s):
            // Quote strings that would be mis-parsed as other types, or contain
            // YAML-special characters.
            let needsQuoting = s.isEmpty
                || s == "~"
                || ["null", "true", "false", "yes", "no", "on", "off"]
                    .contains(s.lowercased())
                || Int64(s) != nil
                || Double(s) != nil
                || s.contains(":")
                || s.contains("#")
                || s.contains("\n")
                || s.hasPrefix(" ") || s.hasSuffix(" ")
            if needsQuoting {
                // Single-quote with escaped single quotes.
                return "'\(s.replacingOccurrences(of: "'", with: "''"))'"
            }
            return s
        case .integer(let n): return "\(n)"
        case .float(let f):
            if f.isNaN      { return ".nan" }
            if f.isInfinite { return f > 0 ? ".inf" : "-.inf" }
            return "\(f)"
        case .boolean(let b): return b ? "true" : "false"
        case .null:           return "~"
        }
    }
}

// MARK: - Errors

public enum YAMLParserError: Error, Sendable {
    case encodingError
    case parseFailed
    case cannotSerializeContainer
    case noValueToSerialize
}
