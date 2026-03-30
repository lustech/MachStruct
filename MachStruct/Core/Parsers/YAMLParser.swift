import Foundation
import Yams

// MARK: - YAMLParser

/// Event-driven YAML parser built on Yams (libyaml wrapper).
///
/// **Phase 1** — `buildIndex(from:)`:
///   Calls `Yams.compose()` to get the raw YAML AST, then recursively walks it
///   to produce a flat `IndexEntry` array in document order.
///
///   Node mapping:
///   - YAML mapping  → `.object`   (key-value pairs become `.keyValue` children)
///   - YAML sequence → `.array`    (items are indexed children `"0"`, `"1"`, …)
///   - YAML scalar   → `.scalar`   (type inferred from tag or string content)
///
///   Anchor names are captured eagerly in `YAMLMetadata.anchor`.
///   Aliases are resolved by Yams before we walk the tree; the resolved node
///   receives a fresh `NodeID` but no alias marker (Phase 4 can add tracking).
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
        let data = try file.data(offset: 0, length: length)
        guard let yamlString = String(data: data, encoding: .utf8) else {
            throw YAMLParserError.encodingError
        }

        var entries: [IndexEntry] = []
        entries.reserveCapacity(256)

        // compose() returns the first document root, or nil for whitespace-only content.
        guard let root = try Yams.compose(yaml: yamlString) else {
            entries.append(IndexEntry(id: .generate(), nodeType: .object, depth: 0, parentID: nil))
            return StructuralIndex(entries: entries)
        }

        walkNode(root, parentID: nil, depth: 0, key: nil, into: &entries)
        return StructuralIndex(entries: entries)
    }

    // MARK: - Progressive streaming

    public nonisolated func parseProgressively(file: MappedFile) -> AsyncStream<ParseProgress> {
        AsyncStream { continuation in
            Task {
                do {
                    let parser = YAMLParser()
                    let index = try await parser.buildIndex(from: file)
                    let batchSize = 1_000
                    var batch: [IndexEntry] = []
                    batch.reserveCapacity(batchSize)
                    for entry in index.entries {
                        batch.append(entry)
                        if batch.count == batchSize {
                            continuation.yield(.nodesIndexed(batch))
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                    if !batch.isEmpty { continuation.yield(.nodesIndexed(batch)) }
                    continuation.yield(.complete(index))
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
        }
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
            _ = try Yams.compose(yaml: yamlString)
            return []
        } catch {
            return [ValidationIssue(severity: .error, message: error.localizedDescription)]
        }
    }
}

// MARK: - Tree walker

private extension YAMLParser {

    /// Recursively walk one Yams `Node` and append `IndexEntry` values in pre-order.
    nonisolated func walkNode(
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
            let meta = YAMLMetadata(anchor: mapping.anchor?.rawValue, scalarStyle: .plain)
            entries.append(IndexEntry(
                id: nodeID,
                nodeType: .object,
                depth: depth,
                parentID: parentID,
                childCount: UInt32(mapping.count),
                key: key,
                metadata: .yaml(meta)
            ))
            for (keyNode, valueNode) in mapping {
                guard case .scalar(let ks) = keyNode else { continue }
                let kvID = NodeID.generate()
                entries.append(IndexEntry(
                    id: kvID,
                    nodeType: .keyValue,
                    depth: depth + 1,
                    parentID: nodeID,
                    childCount: 1,
                    key: ks.string
                ))
                walkNode(valueNode, parentID: kvID, depth: depth + 2, key: nil, into: &entries)
            }

        // MARK: Sequence → .array + positional children

        case .sequence(let sequence):
            let nodeID = NodeID.generate()
            let meta = YAMLMetadata(anchor: sequence.anchor?.rawValue, scalarStyle: .plain)
            entries.append(IndexEntry(
                id: nodeID,
                nodeType: .array,
                depth: depth,
                parentID: parentID,
                childCount: UInt32(sequence.count),
                key: key,
                metadata: .yaml(meta)
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
            let meta = YAMLMetadata(anchor: scalar.anchor?.rawValue, tag: customTag, scalarStyle: style)
            entries.append(IndexEntry(
                id: nodeID,
                nodeType: .scalar,
                depth: depth,
                parentID: parentID,
                childCount: 0,
                key: key,
                parsedValue: sv,
                metadata: .yaml(meta)
            ))

        @unknown default:
            break
        }
    }

    // MARK: - Scalar type inference

    /// Infer a `ScalarValue` from a Yams scalar node.
    ///
    /// Uses the resolved YAML tag when available, then falls back to heuristic
    /// string matching (same rules as YAML 1.1 implicit resolution).
    nonisolated func inferType(_ scalar: Yams.Node.Scalar) -> ScalarValue {
        let tag = scalar.tag.description
        let str = scalar.string

        // Quoted strings are always strings regardless of content.
        if scalar.style == .singleQuoted || scalar.style == .doubleQuoted {
            return .string(str)
        }

        // Explicit tag takes priority.
        if tag.hasSuffix(":str")  { return .string(str) }
        if tag.hasSuffix(":null") { return .null }
        if tag.hasSuffix(":bool") { return boolValue(str) }
        if tag.hasSuffix(":int")  { return intValue(str) }
        if tag.hasSuffix(":float") { return floatValue(str) }

        // Implicit resolution.
        if str.isEmpty || str == "~" || str.lowercased() == "null" { return .null }
        switch str.lowercased() {
        case "true", "yes", "on":  return .boolean(true)
        case "false", "no", "off": return .boolean(false)
        default: break
        }
        if let i = Int64(str)   { return .integer(i) }
        if let f = Double(str)  { return .float(f) }
        return .string(str)
    }

    nonisolated func boolValue(_ str: String) -> ScalarValue {
        .boolean(["true", "yes", "on", "1"].contains(str.lowercased()))
    }

    nonisolated func intValue(_ str: String) -> ScalarValue {
        if str.hasPrefix("0x") || str.hasPrefix("0X") {
            return .integer(Int64(str.dropFirst(2), radix: 16) ?? 0)
        }
        if str.hasPrefix("0o") {
            return .integer(Int64(str.dropFirst(2), radix: 8) ?? 0)
        }
        return .integer(Int64(str) ?? 0)
    }

    nonisolated func floatValue(_ str: String) -> ScalarValue {
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
        let desc = tag.description
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
