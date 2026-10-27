import Foundation
import CSimdjsonBridge

// MARK: - JSONSource

/// A large JSON document read straight from its bytes (ADR-002).
///
/// Opening validates the file in one pass and keeps only where each child of
/// the root starts. Every other node is built from the bytes when asked for,
/// so memory does not grow with the number of nodes.
///
/// A node's ID encodes where it starts: `base + 4 × offset + kind`, where
/// `kind` is 0 for a value and 1 for an object member (whose offset is its
/// key's). Any node therefore has an ID before it is ever built.
public final class JSONSource: DocumentSource, @unchecked Sendable {

    public let file: MappedFile
    public let rootID: NodeID
    public let nodeCount: Int
    /// Shares key strings between the nodes this source builds.
    public let keyTable = StringTable()

    private let base: UInt64
    private let rootOffset: UInt64
    private let rootEnd: UInt64
    /// Where each child of the root starts. Kept so finding a node's ancestors
    /// starts with a binary search rather than a scan of the whole file.
    private let rootChildOffsets: [UInt64]

    private enum Kind: UInt64 {
        case value = 0
        case member = 1
    }

    /// Validates `file`. Throws `ParseError` at the first problem.
    public init(file: MappedFile) throws {
        self.file = file
        let data = file.rawPointer.assumingMemoryBound(to: CChar.self)
        var info = MSJSONInfo()
        var error = MSJSONError()
        guard ms_json_validate(data, file.fileSize, &info, &error) == 1 else {
            let source = UnsafeRawBufferPointer(start: file.rawPointer, count: Int(file.fileSize))
            throw ParseError(problem: String(cString: error.message),
                             byteOffset: Int(error.offset), in: source)
        }
        base = NodeID.reserveBlock(count: Int(4 * (file.fileSize + 1)))
        rootOffset = info.root_offset
        rootEnd = info.root_end
        nodeCount = Int(info.node_count)
        rootID = NodeID(rawValue: base + 4 * info.root_offset)

        var offsets = [UInt64](repeating: 0, count: Int(info.root_child_count))
        if !offsets.isEmpty {
            _ = ms_json_child_offsets(data, file.fileSize, info.root_offset,
                                      &offsets, UInt64(offsets.count), nil)
        }
        rootChildOffsets = offsets
    }

    // MARK: IDs

    private func id(_ offset: UInt64, _ kind: Kind) -> NodeID {
        NodeID(rawValue: base + 4 * offset + kind.rawValue)
    }

    private func locate(_ id: NodeID) -> (offset: UInt64, kind: Kind)? {
        guard id.rawValue >= base else { return nil }
        let raw = id.rawValue - base
        let offset = raw / 4
        guard offset < file.fileSize, let kind = Kind(rawValue: raw % 4) else { return nil }
        return (offset, kind)
    }

    private var bytes: UnsafePointer<CChar> {
        file.rawPointer.assumingMemoryBound(to: CChar.self)
    }

    private func byte(at offset: UInt64) -> UInt8 {
        file.rawPointer.load(fromByteOffset: Int(offset), as: UInt8.self)
    }

    private func buffer(_ start: UInt64, _ end: UInt64) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: file.rawPointer + Int(start), count: Int(end - start))
    }

    /// The children of the container at `offset` and where it ends.
    private func children(ofContainerAt offset: UInt64) -> (offsets: [UInt64], end: UInt64) {
        if offset == rootOffset { return (rootChildOffsets, rootEnd) }
        var end: UInt64 = 0
        var small = [UInt64](repeating: 0, count: 64)
        let count = ms_json_child_offsets(bytes, file.fileSize, offset, &small, 64, &end)
        if count <= 64 { return (Array(small.prefix(Int(count))), end) }
        var all = [UInt64](repeating: 0, count: Int(count))
        _ = ms_json_child_offsets(bytes, file.fileSize, offset, &all, count, nil)
        return (all, end)
    }

    // MARK: DocumentSource

    public func node(for id: NodeID, parent: DocumentNode?, internKeys: Bool) -> DocumentNode? {
        guard let (offset, kind) = locate(id) else { return nil }
        let depth = parent.map { $0.depth + 1 } ?? 0

        if kind == .member {
            var keyEnd: UInt64 = 0, valueOffset: UInt64 = 0
            ms_json_member(bytes, file.fileSize, offset, &keyEnd, &valueOffset)
            var key = JSONParser.decodeStringToken(buffer(offset, keyEnd))
            if internKeys { key = keyTable.intern(key) }
            return DocumentNode(id: id, type: .keyValue, depth: depth, parentID: parent?.id,
                                childIDs: [self.id(valueOffset, .value)], key: key,
                                value: .unparsed,
                                sourceRange: SourceRange(byteOffset: offset,
                                                         byteLength: UInt32(clamping: keyEnd - offset)))
        }

        switch byte(at: offset) {
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            let isObject = byte(at: offset) == UInt8(ascii: "{")
            let (offsets, end) = children(ofContainerAt: offset)
            let childKind: Kind = isObject ? .member : .value
            return DocumentNode(id: id, type: isObject ? .object : .array, depth: depth,
                                parentID: parent?.id,
                                childIDs: offsets.map { self.id($0, childKind) },
                                value: .container(childCount: offsets.count),
                                sourceRange: SourceRange(byteOffset: offset,
                                                         byteLength: UInt32(clamping: end - offset)))
        default:
            let end = ms_json_value_end(bytes, file.fileSize, offset)
            let value = JSONParser.decodeScalarBytes(buffer(offset, end)).map(NodeValue.scalar)
                ?? .unparsed
            return DocumentNode(id: id, type: .scalar, depth: depth, parentID: parent?.id,
                                value: value,
                                sourceRange: SourceRange(byteOffset: offset,
                                                         byteLength: UInt32(clamping: end - offset)))
        }
    }

    public func path(to id: NodeID) -> [NodeID] {
        guard let (target, _) = locate(id) else { return [] }
        var path = [rootID]
        if id == rootID { return path }
        var container = rootOffset
        while true {
            let first = byte(at: container)
            guard first == UInt8(ascii: "{") || first == UInt8(ascii: "[") else { return [] }
            let offsets = children(ofContainerAt: container).offsets
            // The last child that starts at or before the target holds it.
            var lo = 0, hi = offsets.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if offsets[mid] <= target { lo = mid + 1 } else { hi = mid }
            }
            guard lo > 0 else { return [] }
            let start = offsets[lo - 1]

            var value = start
            if first == UInt8(ascii: "{") {
                let member = self.id(start, .member)
                path.append(member)
                if member == id { return path }
                var keyEnd: UInt64 = 0
                ms_json_member(bytes, file.fileSize, start, &keyEnd, &value)
            }
            let valueID = self.id(value, .value)
            path.append(valueID)
            if valueID == id { return path }
            guard target > value else { return [] }
            container = value
        }
    }

    public func looksTabular() -> Bool {
        guard byte(at: rootOffset) == UInt8(ascii: "["), !rootChildOffsets.isEmpty else {
            return false
        }
        var firstKeys: [String]?
        for start in rootChildOffsets.prefix(10) {
            guard byte(at: start) == UInt8(ascii: "{") else { return false }
            let keys = children(ofContainerAt: start).offsets.map { member -> String in
                var keyEnd: UInt64 = 0, value: UInt64 = 0
                ms_json_member(bytes, file.fileSize, member, &keyEnd, &value)
                return JSONParser.decodeStringToken(buffer(member, keyEnd)) ?? ""
            }
            guard !keys.isEmpty else { return false }
            if let firstKeys, keys != firstKeys { return false }
            firstKeys = keys
        }
        return true
    }

    // MARK: Search

    /// Each key and scalar in the subtree at `id` whose text may contain
    /// `needle` (lowercase UTF-8), in document order, with the row that shows
    /// it. Skipping the rest without decoding them is what makes searching a
    /// large file fast. Return `false` from `visit` to stop.
    public func searchCandidates(
        in id: NodeID, needle: [UInt8],
        _ visit: (_ row: NodeID, _ field: SearchMatch.Field, _ token: UnsafeRawBufferPointer) -> Bool
    ) {
        guard let (offset, kind) = locate(id) else { return }
        // The C scan only rules tokens out by ASCII bytes.
        let asciiNeedle = needle.allSatisfy { $0 < 0x80 } ? needle : []
        typealias Visit = (MSJSONToken) -> Bool
        withoutActuallyEscaping({ (token: MSJSONToken) -> Bool in
            let row = self.id(token.row_offset, token.row_is_member == 1 ? .member : .value)
            return visit(row, token.is_key == 1 ? .key : .value,
                         self.buffer(token.offset, token.end))
        } as Visit) { body in
            var box = body
            withUnsafeMutablePointer(to: &box) { context in
                asciiNeedle.withUnsafeBufferPointer { needleBytes in
                    needleBytes.withMemoryRebound(to: CChar.self) { n in
                        ms_json_search(bytes, file.fileSize, offset, kind == .member ? 1 : 0,
                                       n.baseAddress, UInt64(n.count),
                                       { context, token in
                                           let visit = context!.assumingMemoryBound(to: Visit.self)
                                           return visit.pointee(token!.pointee) ? 1 : 0
                                       }, context)
                    }
                }
            }
        }
    }
}
