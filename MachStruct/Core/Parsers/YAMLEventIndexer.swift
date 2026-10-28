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
        guard count < Int(UInt32.max),
              let storage = YAMLSource.Storage.parse(bytes, count: count) else { return nil }
        return storage.indexEntries(bytes: bytes,
                                    base: NodeID.reserveBlock(count: storage.count))
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
}
