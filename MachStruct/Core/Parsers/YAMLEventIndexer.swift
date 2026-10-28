import Foundation
import CYaml

// MARK: - YAMLEventIndexer

/// Builds a YAML file's index entries straight from libyaml's events.
///
/// `Yams.compose_all` builds a tree of every node before the parser walks it
/// into entries: for a 20 MB file, 400 MB and two seconds on top of the
/// entries themselves. The events carry everything the entries hold, so this
/// appends each entry as its event arrives and keeps no tree.
///
/// The entries are exactly what composing and walking gives. Where matching
/// it would mean reproducing the composer — aliases, which it expands into
/// copies of the anchored node; keys that aren't scalars; keys that may be
/// duplicates, which it rejects or keeps depending on their resolved tags;
/// and parse errors, whose messages it builds — this returns `nil` and the
/// caller composes instead.
enum YAMLEventIndexer {

    static func entries(_ bytes: UnsafeRawPointer, count: Int) -> [IndexEntry]? {
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) == 1 else { return nil }
        defer { yaml_parser_delete(&parser) }
        yaml_parser_set_encoding(&parser, YAML_UTF8_ENCODING)
        yaml_parser_set_input_string(&parser, bytes.assumingMemoryBound(to: UInt8.self), count)

        var builder = Builder()
        builder.entries.reserveCapacity(estimatedEntryCount(bytes, count: count))
        var event = yaml_event_t()
        while true {
            guard yaml_parser_parse(&parser, &event) == 1 else { return nil }
            defer { yaml_event_delete(&event) }
            switch event.type {
            case YAML_STREAM_END_EVENT:
                return builder.finish()
            case YAML_SCALAR_EVENT:
                guard builder.scalar(event) else { return nil }
            case YAML_SEQUENCE_START_EVENT:
                let start = event.data.sequence_start
                guard builder.open(.array, anchor: string(start.anchor)) else { return nil }
            case YAML_MAPPING_START_EVENT:
                let start = event.data.mapping_start
                guard builder.open(.object, anchor: string(start.anchor)) else { return nil }
            case YAML_SEQUENCE_END_EVENT, YAML_MAPPING_END_EVENT:
                builder.close()
            case YAML_ALIAS_EVENT:
                return nil
            default:
                // Stream start and document start and end.
                continue
            }
        }
    }

    /// How many entries a file of `count` bytes will have, from the events in
    /// its first few megabytes. Reserving them up front matters: growing the
    /// array by doubling peaked at nearly twice its final size.
    static func estimatedEntryCount(_ bytes: UnsafeRawPointer, count: Int,
                                    sampleSize: Int = 4 << 20) -> Int {
        guard count > sampleSize else { return 0 }
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) == 1 else { return 0 }
        defer { yaml_parser_delete(&parser) }
        yaml_parser_set_encoding(&parser, YAML_UTF8_ENCODING)
        yaml_parser_set_input_string(&parser, bytes.assumingMemoryBound(to: UInt8.self), sampleSize)

        // Each scalar is one entry (a key's is its pair's), and each
        // collection one. The sample ends mid-document, which stops the
        // parser with an error.
        var nodes = 0
        var consumed = 0
        var event = yaml_event_t()
        while yaml_parser_parse(&parser, &event) == 1 {
            defer { yaml_event_delete(&event) }
            switch event.type {
            case YAML_SCALAR_EVENT, YAML_SEQUENCE_START_EVENT, YAML_MAPPING_START_EVENT:
                nodes += 1
                consumed = event.end_mark.index
            case YAML_STREAM_END_EVENT:
                return nodes
            default:
                continue
            }
        }
        guard consumed > 0 else { return 0 }
        return Int(Double(nodes) * Double(count) / Double(consumed) * 1.02)
    }

    private static func string(_ chars: UnsafeMutablePointer<yaml_char_t>?) -> String? {
        chars.map { String(cString: $0) }
    }

    // MARK: - Building

    /// One metadata box for each style, for the nodes with no anchor or tag:
    /// nearly all of them.
    static let plainMetadata: [YAMLScalarStyle: IndexEntry.MetadataBox] = Dictionary(
        uniqueKeysWithValues: [YAMLScalarStyle.plain, .singleQuoted, .doubleQuoted, .literal, .folded]
            .map { ($0, IndexEntry.MetadataBox(.yaml(YAMLMetadata(scalarStyle: $0)))) })

    static func metadata(anchor: String?, tag: String?, style: YAMLScalarStyle) -> IndexEntry.MetadataBox {
        if anchor == nil, tag == nil, let shared = plainMetadata[style] { return shared }
        return IndexEntry.MetadataBox(.yaml(YAMLMetadata(anchor: anchor, tag: tag, scalarStyle: style)))
    }

    private struct Container {
        let entryIndex: Int
        let id: NodeID
        let depth: UInt16
        let isMapping: Bool
        var count: UInt32 = 0
        /// A mapping's pair whose value comes next, if any.
        var pairID: NodeID?
        /// A mapping's keys, for the duplicate check: an array while there
        /// are few, which is cheaper than a set for the common small mapping.
        var keys: [String] = []
        var keySet: Set<String>?

        /// Records `key`, or returns false if the mapping already has it.
        mutating func insert(key: String) -> Bool {
            if keySet != nil { return keySet!.insert(key).inserted }
            if keys.contains(key) { return false }
            keys.append(key)
            if keys.count > 16 {
                keySet = Set(keys)
                keys = []
            }
            return true
        }
    }

    private struct Builder {
        var entries: [IndexEntry] = []
        var stack: [Container] = []
        /// The entry index of each document's root.
        var documentRoots: [Int] = []

        /// Where a node starting now goes: its parent, depth and key.
        private mutating func place() -> (NodeID?, UInt16, String?) {
            guard var top = stack.popLast() else {
                documentRoots.append(entries.count)
                return (nil, 0, nil)
            }
            defer { stack.append(top) }
            if top.isMapping {
                let pair = top.pairID
                top.pairID = nil
                return (pair, top.depth + 2, nil)
            }
            top.count += 1
            return (top.id, top.depth + 1, String(top.count - 1))
        }

        private var expectsKey: Bool {
            guard let top = stack.last else { return false }
            return top.isMapping && top.pairID == nil
        }

        mutating func scalar(_ event: yaml_event_t) -> Bool {
            let scalar = event.data.scalar
            let text = String(decoding: UnsafeBufferPointer(start: scalar.value, count: scalar.length),
                              as: UTF8.self)
            if expectsKey {
                guard stack[stack.count - 1].insert(key: text) else { return false }
                let top = stack[stack.count - 1]
                let pairID = NodeID.generate()
                entries.append(IndexEntry(id: pairID, nodeType: .keyValue, depth: top.depth + 1,
                                          parentID: top.id, childCount: 1, key: text))
                stack[stack.count - 1].count += 1
                stack[stack.count - 1].pairID = pairID
                return true
            }

            let (parentID, depth, key) = place()
            // As the composer does: an untagged quoted or block scalar is a
            // string, a plain one has no tag yet.
            let tag = scalar.quoted_implicit == 1
                ? "tag:yaml.org,2002:str"
                : YAMLEventIndexer.string(scalar.tag) ?? ""
            let style = Self.style(scalar.style)
            let value = YAMLParser.inferType(text, tag: tag,
                                             quoted: style == .singleQuoted || style == .doubleQuoted)
            let box = YAMLEventIndexer.metadata(anchor: YAMLEventIndexer.string(scalar.anchor),
                                                tag: YAMLParser.nonStandardTag(tag), style: style)
            entries.append(IndexEntry(id: .generate(), nodeType: .scalar, depth: depth,
                                      parentID: parentID, childCount: 0, key: key,
                                      parsedValue: value, sharedMetadata: box))
            return true
        }

        mutating func open(_ type: NodeType, anchor: String?) -> Bool {
            guard !expectsKey else { return false }
            let (parentID, depth, key) = place()
            let id = NodeID.generate()
            stack.append(Container(entryIndex: entries.count, id: id, depth: depth,
                                   isMapping: type == .object))
            entries.append(IndexEntry(id: id, nodeType: type, depth: depth, parentID: parentID,
                                      key: key,
                                      sharedMetadata: YAMLEventIndexer.metadata(anchor: anchor, tag: nil,
                                                                                style: .plain)))
            return true
        }

        mutating func close() {
            guard let container = stack.popLast() else { return }
            entries[container.entryIndex] = entries[container.entryIndex].with(childCount: container.count)
        }

        /// The entries, with a file of several documents indexed as the
        /// items of a root sequence, as `YAMLParser.indexEntries(forDocuments:)`.
        mutating func finish() -> [IndexEntry] {
            switch documentRoots.count {
            case 0:
                return [IndexEntry(id: .generate(), nodeType: .object, depth: 0, parentID: nil)]
            case 1:
                return entries
            default:
                let rootID = NodeID.generate()
                var result = [IndexEntry(id: rootID, nodeType: .array, depth: 0, parentID: nil,
                                         childCount: UInt32(documentRoots.count),
                                         metadata: .yaml(YAMLMetadata(isDocumentStream: true)))]
                result.reserveCapacity(entries.count + 1)
                var nextRoot = 0
                for (i, entry) in entries.enumerated() {
                    if nextRoot < documentRoots.count, documentRoots[nextRoot] == i {
                        result.append(entry.with(depth: entry.depth + 1, parentID: rootID,
                                                 key: String(nextRoot)))
                        nextRoot += 1
                    } else {
                        result.append(entry.with(depth: entry.depth + 1))
                    }
                }
                entries = []
                return result
            }
        }

        private static func style(_ style: yaml_scalar_style_t) -> YAMLScalarStyle {
            switch style {
            case YAML_SINGLE_QUOTED_SCALAR_STYLE: return .singleQuoted
            case YAML_DOUBLE_QUOTED_SCALAR_STYLE: return .doubleQuoted
            case YAML_LITERAL_SCALAR_STYLE:       return .literal
            case YAML_FOLDED_SCALAR_STYLE:        return .folded
            default:                              return .plain
            }
        }
    }
}
