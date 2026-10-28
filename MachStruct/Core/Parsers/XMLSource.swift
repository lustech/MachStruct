import Foundation

// MARK: - XMLSource

/// A large XML file's nodes, built on demand from a compact record of each
/// (ADR-002), as `YAMLSource` does for YAML.
///
/// One SAX pass keeps, per node, its kind, parent and extent, and an
/// element's name or a text node's text: about 21 bytes a node, against 88
/// for an `IndexEntry` plus a metadata box with its own attribute array for
/// every element. Names, namespaces and attribute keys are interned; text
/// and attribute values are kept in one byte arena.
///
/// An element is an `.object` keyed by its name, with its namespace,
/// attributes (sorted by key) and whether it is empty in `XMLMetadata`; its
/// text, trimmed and split around child elements, is `.scalar` children.
public final class XMLSource: DocumentSource, @unchecked Sendable {

    private let base: UInt64
    private let storage: Storage

    /// Parses `file`, throwing the parser's error when it isn't well-formed.
    public init(file: MappedFile) throws {
        storage = try Storage.parse(file)
        base = NodeID.reserveBlock(count: storage.count)
    }

    public var rootID: NodeID { NodeID(rawValue: base) }

    public var nodeCount: Int { storage.count }

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
        return DocumentNode(
            id: id,
            type: storage.isElement(i) ? .object : .scalar,
            depth: depth,
            parentID: parentIndex.map(nodeID),
            childIDs: childIDs,
            key: storage.name(of: i),
            value: storage.value(of: i, childCount: childIDs.count),
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

    /// An XML root is an element, never an array.
    public func looksTabular() -> Bool { false }

    /// The file's index entries, numbered as this source's nodes.
    func indexEntries() -> [IndexEntry] {
        storage.indexEntries(base: base)
    }

    private func index(of id: NodeID) -> Int? {
        guard id.rawValue >= base else { return nil }
        let i = id.rawValue - base
        return i < UInt64(storage.count) ? Int(i) : nil
    }

    private func nodeID(_ i: Int) -> NodeID { NodeID(rawValue: base + UInt64(i)) }
}

// MARK: - Storage

extension XMLSource {

    /// One record per node, as parallel arrays.
    struct Storage {
        /// Bit 0: a text node rather than an element.
        private(set) var kinds: [UInt8] = []
        private(set) var parents: [UInt32] = []
        /// The record after this node's subtree.
        private(set) var ends: [UInt32] = []
        /// An element's interned name and namespace.
        private(set) var names: [UInt32] = []
        /// A text node's text in `arena`; an element's attributes, as the
        /// first of them in `attributeKeys` and how many.
        private(set) var starts: [UInt32] = []
        private(set) var lengths: [UInt32] = []

        private(set) var qualifiedNames: [(name: String, namespace: String?)] = []
        private(set) var attributeNames: [String] = []
        private(set) var attributeKeys: [UInt32] = []
        private(set) var attributeValueStarts: [UInt32] = []
        private(set) var attributeValueLengths: [UInt32] = []
        private(set) var arena: [UInt8] = []

        var count: Int { kinds.count }

        static let noParent = UInt32.max
        private static let text: UInt8 = 1

        // MARK: Reading

        func isElement(_ i: Int) -> Bool { kinds[i] & Self.text == 0 }

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
            var child = i + 1
            let end = Int(ends[i])
            while child < end {
                body(child)
                child = Int(ends[child])
            }
        }

        func name(of i: Int) -> String? {
            isElement(i) ? qualifiedNames[Int(names[i])].name : nil
        }

        private func string(_ start: UInt32, _ length: UInt32) -> String {
            arena.withUnsafeBufferPointer {
                String(decoding: UnsafeBufferPointer(rebasing: $0[Int(start)..<Int(start + length)]),
                       as: UTF8.self)
            }
        }

        func value(of i: Int, childCount: Int) -> NodeValue {
            isElement(i) ? .container(childCount: childCount) : .scalar(.string(string(starts[i], lengths[i])))
        }

        func metadata(of i: Int) -> FormatMetadata? {
            guard isElement(i) else { return nil }
            let first = Int(starts[i])
            let attributes = (first ..< first + Int(lengths[i])).map {
                (key: attributeNames[Int(attributeKeys[$0])],
                 value: string(attributeValueStarts[$0], attributeValueLengths[$0]))
            }
            return .xml(XMLMetadata(namespace: qualifiedNames[Int(names[i])].namespace,
                                    attributes: attributes,
                                    isSelfClosing: ends[i] == UInt32(i + 1)))
        }

        func indexEntries(base: UInt64) -> [IndexEntry] {
            var entries: [IndexEntry] = []
            entries.reserveCapacity(count)
            var depths: [UInt16] = []
            depths.reserveCapacity(count)
            for i in 0..<count {
                let parent = parent(of: i)
                let depth = parent.map { depths[$0] + 1 } ?? 0
                depths.append(depth)
                var childCount: UInt32 = 0
                forEachChild(of: i) { _ in childCount += 1 }
                var parsedValue: ScalarValue?
                if case .scalar(let value) = value(of: i, childCount: 0) { parsedValue = value }
                entries.append(IndexEntry(
                    id: NodeID(rawValue: base + UInt64(i)), nodeType: isElement(i) ? .object : .scalar,
                    depth: depth, parentID: parent.map { NodeID(rawValue: base + UInt64($0)) },
                    childCount: childCount, key: name(of: i), parsedValue: parsedValue,
                    metadata: metadata(of: i)))
            }
            return entries
        }

        // MARK: Building

        /// Parses `file` into records, throwing the parser's error.
        static func parse(_ file: MappedFile) throws -> Storage {
            guard file.fileSize < UInt64(UInt32.max) else { throw XMLParserError.parseFailed }
            // The parser reads the mapped bytes in place.
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: file.rawPointer),
                            count: Int(file.fileSize), deallocator: .none)
            let builder = Builder()
            builder.storage.reserve(estimatedNodes(in: file))
            let parser = Foundation.XMLParser(data: data)
            parser.delegate = builder
            parser.shouldProcessNamespaces = true
            parser.shouldReportNamespacePrefixes = false
            guard parser.parse() else {
                throw XMLParser.parseError(from: builder.parseError, in: data)
            }
            guard builder.storage.count < Int(noParent), builder.storage.arena.count < Int(UInt32.max) else {
                throw XMLParserError.parseFailed
            }
            return builder.storage
        }

        /// About as many nodes as `file` will have, so the arrays needn't
        /// grow by doubling, which peaked at nearly twice their size: each
        /// element takes one or two `<`, and its text runs are at most as
        /// many as its children plus one. Pages reserved and never written
        /// aren't resident.
        private static func estimatedNodes(in file: MappedFile) -> Int {
            var count = 0
            var p = file.rawPointer
            let end = file.rawPointer + Int(file.fileSize)
            while p < end, let found = memchr(p, Int32(UInt8(ascii: "<")), end - p) {
                count += 1
                p = UnsafeRawPointer(found) + 1
            }
            return count
        }

        fileprivate mutating func reserve(_ n: Int) {
            kinds.reserveCapacity(n); parents.reserveCapacity(n); ends.reserveCapacity(n)
            names.reserveCapacity(n); starts.reserveCapacity(n); lengths.reserveCapacity(n)
        }

        fileprivate mutating func appendElement(parent: Int?, name: UInt32,
                                                attributes: (start: Int, count: Int)) {
            kinds.append(0)
            parents.append(parent.map(UInt32.init) ?? Self.noParent)
            ends.append(UInt32(count))
            names.append(name)
            starts.append(UInt32(attributes.start))
            lengths.append(UInt32(attributes.count))
        }

        fileprivate mutating func appendText(_ text: Substring, parent: Int) {
            let start = arena.count
            arena.append(contentsOf: text.utf8)
            kinds.append(Self.text)
            parents.append(UInt32(parent))
            ends.append(UInt32(count))
            names.append(0)
            starts.append(UInt32(start))
            lengths.append(UInt32(arena.count - start))
        }

        fileprivate mutating func close(_ i: Int) {
            ends[i] = UInt32(count)
        }

        fileprivate mutating func intern(name: String, namespace: String?,
                                         in table: inout [NameKey: UInt32]) -> UInt32 {
            let key = NameKey(name: name, namespace: namespace)
            if let id = table[key] { return id }
            let id = UInt32(qualifiedNames.count)
            qualifiedNames.append((name, namespace))
            table[key] = id
            return id
        }

        fileprivate mutating func appendAttributes(_ attributes: [(key: String, value: String)],
                                                   interning table: inout [String: UInt32]) -> (Int, Int) {
            let start = attributeKeys.count
            for (key, value) in attributes {
                let id: UInt32
                if let known = table[key] {
                    id = known
                } else {
                    id = UInt32(attributeNames.count)
                    attributeNames.append(key)
                    table[key] = id
                }
                attributeKeys.append(id)
                let valueStart = arena.count
                arena.append(contentsOf: value.utf8)
                attributeValueStarts.append(UInt32(valueStart))
                attributeValueLengths.append(UInt32(arena.count - valueStart))
            }
            return (start, attributes.count)
        }
    }

    fileprivate struct NameKey: Hashable {
        let name: String
        let namespace: String?
    }

    /// Records SAX callbacks: an element's text is gathered until a child
    /// element starts or it ends, then trimmed and kept if anything is left.
    private final class Builder: NSObject, Foundation.XMLParserDelegate {
        var storage = Storage()
        var parseError: Error?
        private var stack: [(index: Int, text: String)] = []
        private var names: [NameKey: UInt32] = [:]
        private var attributeNames: [String: UInt32] = [:]

        private func flushText() {
            guard let top = stack.indices.last else { return }
            let text = stack[top].text
            stack[top].text = ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            storage.appendText(trimmed[...], parent: stack[top].index)
        }

        func parser(_ parser: Foundation.XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName _: String?,
                    attributes attributeDict: [String: String]) {
            flushText()
            let namespace = namespaceURI?.isEmpty == false ? namespaceURI : nil
            let name = storage.intern(name: elementName, namespace: namespace, in: &names)
            let attributes = storage.appendAttributes(
                attributeDict.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
                interning: &attributeNames)
            let index = storage.count
            storage.appendElement(parent: stack.last?.index, name: name, attributes: attributes)
            stack.append((index, ""))
        }

        func parser(_ parser: Foundation.XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: Foundation.XMLParser, foundCDATA CDATABlock: Data) {
            guard !stack.isEmpty, let text = String(data: CDATABlock, encoding: .utf8) else { return }
            stack[stack.count - 1].text += text
        }

        func parser(_ parser: Foundation.XMLParser, didEndElement _: String,
                    namespaceURI _: String?, qualifiedName _: String?) {
            flushText()
            guard let frame = stack.popLast() else { return }
            storage.close(frame.index)
        }

        func parser(_ parser: Foundation.XMLParser, parseErrorOccurred error: Error) {
            parseError = error
        }

        func parser(_ parser: Foundation.XMLParser, validationErrorOccurred error: Error) {
            parseError = parseError ?? error
        }
    }
}
