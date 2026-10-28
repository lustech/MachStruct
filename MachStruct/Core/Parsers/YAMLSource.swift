import Foundation
import CYaml

// MARK: - YAMLSource

/// A large YAML file's nodes, built on demand from a compact record of each
/// (ADR-002).
///
/// YAML can't be parsed from the middle of a file the way JSON can, so this
/// keeps one record per node from a single pass over libyaml's events: its
/// type, parent, extent and text. That is about 21 bytes a node, against 88
/// for an `IndexEntry` plus its child table. A key's or scalar's text points
/// into the file wherever the parsed text is the bytes there, and is copied
/// otherwise (folded, escaped or block text). Values are inferred when a node
/// is built, by the parser's rules.
///
/// Records are numbered in document order, and a node's ID is `base` plus its
/// record. Record 0 is the root of a file of several documents, whose items
/// they are; a file of one document starts at record 1.
///
/// What the event indexer leaves to the composer (aliases, keys that aren't
/// scalars, keys that may be duplicates, errors) makes `init` fail, and the
/// file is indexed as before.
public final class YAMLSource: DocumentSource, @unchecked Sendable {

    private let file: MappedFile
    private let base: UInt64
    private let storage: Storage
    private let keyTable = StringTable()

    /// `nil` when the file needs composing (see the type's documentation) or
    /// is too large for 32-bit offsets.
    public init?(file: MappedFile) {
        guard file.fileSize > 0, file.fileSize < UInt64(UInt32.max),
              let storage = Storage.parse(file.rawPointer, count: Int(file.fileSize)) else { return nil }
        self.file = file
        self.storage = storage
        base = NodeID.reserveBlock(count: storage.count)
    }

    public var rootID: NodeID { NodeID(rawValue: base + UInt64(storage.rootIndex)) }

    public var nodeCount: Int { storage.count - storage.rootIndex }

    public func node(for id: NodeID, parent: DocumentNode?, internKeys: Bool) -> DocumentNode? {
        guard let i = index(of: id) else { return nil }
        var childIDs: [NodeID] = []
        storage.forEachChild(of: i) { childIDs.append(nodeID($0)) }
        let parentIndex = storage.parent(of: i)
        let depth: UInt16
        if let parent, parentIndex.map(nodeID) == parent.id {
            depth = parent.depth + 1
        } else {
            depth = storage.depth(of: i)
        }
        let key = storage.key(of: i, in: file.rawPointer)
        return DocumentNode(
            id: id,
            type: storage.type(of: i),
            depth: depth,
            parentID: parentIndex.map(nodeID),
            childIDs: childIDs,
            key: internKeys ? keyTable.intern(key) : key,
            value: storage.value(of: i, childCount: childIDs.count, in: file.rawPointer),
            sourceRange: SourceRange(byteOffset: 0, byteLength: 0),
            metadata: storage.metadata(of: i)
        )
    }

    public func path(to id: NodeID) -> [NodeID] {
        guard var i = index(of: id) else { return [] }
        var result = [nodeID(i)]
        while let parent = storage.parent(of: i) {
            result.append(nodeID(parent))
            i = parent
        }
        return result.reversed()
    }

    /// As `StructuralIndex.looksTabular()`: the root is an array whose first
    /// ten items are objects with the same keys.
    public func looksTabular() -> Bool {
        let root = storage.rootIndex
        guard storage.type(of: root) == .array else { return false }
        var items: [Int] = []
        storage.forEachChild(of: root) { if items.count < 10 { items.append($0) } }
        guard !items.isEmpty, items.allSatisfy({ storage.type(of: $0) == .object }) else { return false }
        func keys(_ item: Int) -> [String] {
            var keys: [String] = []
            storage.forEachChild(of: item) { keys.append(storage.key(of: $0, in: file.rawPointer) ?? "") }
            return keys
        }
        let first = keys(items[0])
        return !first.isEmpty && items.allSatisfy { keys($0) == first }
    }

    /// The file's index entries, numbered as this source's nodes.
    func indexEntries() -> [IndexEntry] {
        storage.indexEntries(bytes: file.rawPointer, base: base)
    }

    private func index(of id: NodeID) -> Int? {
        guard id.rawValue >= base + UInt64(storage.rootIndex) else { return nil }
        let i = id.rawValue - base
        return i < UInt64(storage.count) ? Int(i) : nil
    }

    private func nodeID(_ i: Int) -> NodeID { NodeID(rawValue: base + UInt64(i)) }
}

// MARK: - Storage

extension YAMLSource {

    /// One record per node, as parallel arrays.
    struct Storage {
        /// Type in bits 0–1, scalar style in bits 2–4, and the flags below.
        private(set) var kinds: [UInt8] = []
        /// The parent's record, or `noParent`.
        private(set) var parents: [UInt32] = []
        /// The record after this node's subtree: its next sibling's, if any.
        private(set) var ends: [UInt32] = []
        /// A key's or scalar's text, in the file or `arena` (`inArena`).
        private(set) var textStarts: [UInt32] = []
        private(set) var textLengths: [UInt32] = []
        /// An array item's or document's position.
        private(set) var positions: [UInt32] = []
        private(set) var arena: [UInt8] = []
        /// Anchors, and tags other than an untagged scalar's.
        private(set) var properties: [Int: (anchor: String?, tag: String?)] = [:]
        private(set) var rootIndex = 1
        private(set) var isDocumentStream = false
        /// No documents: the root is an empty object with no metadata.
        private(set) var isEmpty = false

        var count: Int { kinds.count }

        static let noParent = UInt32.max
        private static let inArena: UInt8 = 1 << 5
        /// Tagged `str` by being quoted or a block scalar without a tag.
        private static let implicitString: UInt8 = 1 << 6
        private static let hasProperties: UInt8 = 1 << 7
        private static let types: [NodeType] = [.object, .array, .keyValue, .scalar]
        private static let styles: [YAMLScalarStyle] = [.plain, .singleQuoted, .doubleQuoted, .literal, .folded]
        static let stringTag = "tag:yaml.org,2002:str"

        // MARK: Reading

        func type(of i: Int) -> NodeType { Self.types[Int(kinds[i] & 3)] }

        func style(of i: Int) -> YAMLScalarStyle { Self.styles[Int((kinds[i] >> 2) & 7)] }

        func parent(of i: Int) -> Int? {
            parents[i] == Self.noParent ? nil : Int(parents[i])
        }

        func depth(of i: Int) -> UInt16 {
            var depth: UInt16 = 0
            var current = i
            while let parent = parent(of: current) { depth += 1; current = parent }
            return depth
        }

        func forEachChild(of i: Int, _ body: (Int) -> Void) {
            guard type(of: i) != .scalar else { return }
            var child = i + 1
            let end = Int(ends[i])
            while child < end {
                body(child)
                child = Int(ends[child])
            }
        }

        func text(of i: Int, in bytes: UnsafeRawPointer) -> String {
            let start = Int(textStarts[i]), length = Int(textLengths[i])
            if kinds[i] & Self.inArena != 0 {
                return arena.withUnsafeBufferPointer {
                    String(decoding: UnsafeBufferPointer(rebasing: $0[start..<start + length]), as: UTF8.self)
                }
            }
            let bytes = UnsafeRawBufferPointer(start: bytes.advanced(by: start), count: length)
            return String(decoding: bytes, as: UTF8.self)
        }

        /// A pair's key, or an array item's or document's position.
        func key(of i: Int, in bytes: UnsafeRawPointer) -> String? {
            if type(of: i) == .keyValue { return text(of: i, in: bytes) }
            guard let parent = parent(of: i), type(of: parent) == .array else { return nil }
            return String(positions[i])
        }

        /// The tag as written; empty for an untagged plain scalar.
        func tag(of i: Int) -> String {
            if kinds[i] & Self.implicitString != 0 { return Self.stringTag }
            return properties[i]?.tag ?? ""
        }

        func anchor(of i: Int) -> String? {
            kinds[i] & Self.hasProperties != 0 ? properties[i]?.anchor : nil
        }

        /// The entries of the records, numbered from `base`.
        func indexEntries(bytes: UnsafeRawPointer, base: UInt64) -> [IndexEntry] {
            var entries: [IndexEntry] = []
            entries.reserveCapacity(count - rootIndex)
            var depths: [UInt16] = []
            depths.reserveCapacity(count)
            for i in 0..<count {
                let parent = parent(of: i)
                let depth = parent.map { depths[$0] + 1 } ?? 0
                depths.append(depth)
                guard i >= rootIndex else { continue }
                let type = type(of: i)
                var childCount: UInt32 = 0
                forEachChild(of: i) { _ in childCount += 1 }
                var parsedValue: ScalarValue?
                if case .scalar(let value) = value(of: i, childCount: 0, in: bytes) { parsedValue = value }
                entries.append(IndexEntry(
                    id: NodeID(rawValue: base + UInt64(i)), nodeType: type, depth: depth,
                    parentID: parent.map { NodeID(rawValue: base + UInt64($0)) },
                    childCount: childCount, key: key(of: i, in: bytes), parsedValue: parsedValue,
                    sharedMetadata: metadataBox(of: i)))
            }
            return entries
        }

        func value(of i: Int, childCount: Int, in bytes: UnsafeRawPointer) -> NodeValue {
            switch type(of: i) {
            case .object, .array: return .container(childCount: childCount)
            case .keyValue: return .unparsed
            case .scalar:
                let style = style(of: i)
                return .scalar(YAMLParser.inferType(text(of: i, in: bytes), tag: tag(of: i),
                                                    quoted: style == .singleQuoted || style == .doubleQuoted))
            }
        }

        func metadata(of i: Int) -> FormatMetadata? {
            metadataBox(of: i)?.value
        }

        func metadataBox(of i: Int) -> IndexEntry.MetadataBox? {
            switch type(of: i) {
            case .keyValue: return nil
            case .scalar:
                return YAMLEventIndexer.metadata(anchor: anchor(of: i),
                                                 tag: YAMLParser.nonStandardTag(tag(of: i)),
                                                 style: style(of: i))
            case .object, .array:
                if i == 0 {
                    if isEmpty { return nil }
                    if isDocumentStream { return Self.documentStreamMetadata }
                }
                return YAMLEventIndexer.metadata(anchor: anchor(of: i), tag: nil, style: .plain)
            }
        }

        private static let documentStreamMetadata = IndexEntry.MetadataBox(
            .yaml(YAMLMetadata(isDocumentStream: true)))

        // MARK: Building

        private struct Container {
            let index: Int
            let isMapping: Bool
            var count: UInt32 = 0
            /// A mapping's pair whose value comes next, if any.
            var pair: Int?
            var keys = KeySet()
        }

        /// A mapping's keys, for the duplicate check: an array while there
        /// are few, which is cheaper than a set for the common small mapping.
        private struct KeySet {
            var keys: [String] = []
            var set: Set<String>?

            /// Records `key`, or returns false if the mapping already has it.
            mutating func insert(_ key: String) -> Bool {
                if set != nil { return set!.insert(key).inserted }
                if keys.contains(key) { return false }
                keys.append(key)
                if keys.count > 16 {
                    set = Set(keys)
                    keys = []
                }
                return true
            }
        }

        private var stack: [Container] = []
        private var documents: UInt32 = 0

        /// The records of the YAML in `bytes`, or `nil` where it needs composing.
        static func parse(_ bytes: UnsafeRawPointer, count: Int) -> Storage? {
            var parser = yaml_parser_t()
            guard yaml_parser_initialize(&parser) == 1 else { return nil }
            defer { yaml_parser_delete(&parser) }
            yaml_parser_set_encoding(&parser, YAML_UTF8_ENCODING)
            yaml_parser_set_input_string(&parser, bytes.assumingMemoryBound(to: UInt8.self), count)

            var storage = Storage()
            storage.reserve(YAMLEventIndexer.estimatedEntryCount(bytes, count: count) + 1)
            // Record 0, the root of a document stream, until it's known
            // whether there is more than one document.
            storage.append(kind: 0, parent: noParent)

            var event = yaml_event_t()
            while true {
                guard yaml_parser_parse(&parser, &event) == 1 else { return nil }
                defer { yaml_event_delete(&event) }
                switch event.type {
                case YAML_STREAM_END_EVENT:
                    storage.finish()
                    guard storage.count < Int(noParent), storage.arena.count < Int(UInt32.max) else { return nil }
                    return storage
                case YAML_SCALAR_EVENT:
                    guard storage.scalar(event, bytes: bytes, count: count) else { return nil }
                case YAML_SEQUENCE_START_EVENT:
                    guard storage.open(.array, anchor: string(event.data.sequence_start.anchor)) else { return nil }
                case YAML_MAPPING_START_EVENT:
                    guard storage.open(.object, anchor: string(event.data.mapping_start.anchor)) else { return nil }
                case YAML_SEQUENCE_END_EVENT, YAML_MAPPING_END_EVENT:
                    storage.close()
                case YAML_ALIAS_EVENT:
                    return nil
                default:
                    // Stream start and document start and end.
                    continue
                }
            }
        }

        private static func string(_ chars: UnsafeMutablePointer<yaml_char_t>?) -> String? {
            chars.map { String(cString: $0) }
        }

        private mutating func reserve(_ n: Int) {
            kinds.reserveCapacity(n); parents.reserveCapacity(n); ends.reserveCapacity(n)
            textStarts.reserveCapacity(n); textLengths.reserveCapacity(n); positions.reserveCapacity(n)
        }

        private mutating func append(kind: UInt8, parent: UInt32, position: UInt32 = 0,
                                     text: (UInt32, UInt32) = (0, 0)) {
            kinds.append(kind)
            parents.append(parent)
            ends.append(UInt32(kinds.count))
            textStarts.append(text.0)
            textLengths.append(text.1)
            positions.append(position)
        }

        private var expectsKey: Bool {
            guard let top = stack.last else { return false }
            return top.isMapping && top.pair == nil
        }

        /// The parent and position of a node starting now.
        private mutating func place() -> (UInt32, UInt32) {
            guard let top = stack.indices.last else {
                documents += 1
                return (0, documents - 1)
            }
            if stack[top].isMapping {
                let pair = stack[top].pair!
                stack[top].pair = nil
                return (UInt32(pair), 0)
            }
            stack[top].count += 1
            return (UInt32(stack[top].index), stack[top].count - 1)
        }

        /// A node that ended: the pair holding it ends with it.
        private mutating func ended(_ i: Int) {
            if let parent = parent(of: i), type(of: parent) == .keyValue {
                ends[parent] = UInt32(count)
            }
        }

        /// Where the scalar's text is: in the file when the parsed text is
        /// the bytes at its start (or just after an opening quote), otherwise
        /// copied to the arena.
        private mutating func locate(_ value: UnsafeBufferPointer<UInt8>, at start: Int,
                                     style: Int, bytes: UnsafeRawPointer, count: Int) -> (UInt32, UInt32, Bool) {
            let quoted = style == 1 || style == 2
            let offset = start + (quoted ? 1 : 0)
            if style <= 2, offset + value.count <= count,
               value.isEmpty || memcmp(bytes.advanced(by: offset), value.baseAddress!, value.count) == 0 {
                return (UInt32(offset), UInt32(value.count), false)
            }
            let arenaStart = arena.count
            arena.append(contentsOf: value)
            return (UInt32(arenaStart), UInt32(value.count), true)
        }

        mutating func scalar(_ event: yaml_event_t, bytes: UnsafeRawPointer, count: Int) -> Bool {
            let scalar = event.data.scalar
            let value = UnsafeBufferPointer(start: scalar.value, count: scalar.length)
            let style = Self.styleCode(scalar.style)
            let (start, length, inArena) = locate(value, at: event.start_mark.index, style: style,
                                                  bytes: bytes, count: count)
            let arenaFlag = inArena ? Self.inArena : 0

            if expectsKey {
                let top = stack.count - 1
                guard stack[top].keys.insert(String(decoding: value, as: UTF8.self)) else { return false }
                stack[top].count += 1
                stack[top].pair = self.count
                append(kind: 2 | arenaFlag, parent: UInt32(stack[top].index), text: (start, length))
                return true
            }

            let (parent, position) = place()
            var kind = 3 | UInt8(style) << 2 | arenaFlag
            // As the composer does: an untagged quoted or block scalar is a
            // string; a plain one has no tag yet.
            let tag = scalar.quoted_implicit == 1 ? nil : Self.string(scalar.tag)
            if scalar.quoted_implicit == 1 { kind |= Self.implicitString }
            let anchor = Self.string(scalar.anchor)
            if anchor != nil || tag != nil {
                kind |= Self.hasProperties
                properties[self.count] = (anchor, tag)
            }
            append(kind: kind, parent: parent, position: position, text: (start, length))
            ended(self.count - 1)
            return true
        }

        mutating func open(_ type: NodeType, anchor: String?) -> Bool {
            guard !expectsKey else { return false }
            let (parent, position) = place()
            var kind: UInt8 = type == .object ? 0 : 1
            if let anchor {
                kind |= Self.hasProperties
                properties[self.count] = (anchor, nil)
            }
            stack.append(Container(index: self.count, isMapping: type == .object))
            append(kind: kind, parent: parent, position: position)
            return true
        }

        mutating func close() {
            guard let container = stack.popLast() else { return }
            ends[container.index] = UInt32(count)
            ended(container.index)
        }

        /// Decide what record 0 is: the root of several documents, an empty
        /// root when there are none, or unused when there is one.
        private mutating func finish() {
            ends[0] = UInt32(count)
            switch documents {
            case 0:
                kinds[0] = 0
                isEmpty = true
                rootIndex = 0
            case 1:
                parents[1] = Self.noParent
                rootIndex = 1
            default:
                kinds[0] = 1
                isDocumentStream = true
                rootIndex = 0
            }
        }

        private static func styleCode(_ style: yaml_scalar_style_t) -> Int {
            switch style {
            case YAML_SINGLE_QUOTED_SCALAR_STYLE: return 1
            case YAML_DOUBLE_QUOTED_SCALAR_STYLE: return 2
            case YAML_LITERAL_SCALAR_STYLE:       return 3
            case YAML_FOLDED_SCALAR_STYLE:        return 4
            default:                              return 0
            }
        }
    }
}
