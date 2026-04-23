import Foundation
import CSimdjsonBridge

// MARK: - JSONParser

/// Two-phase JSON parser.
///
/// **Phase 1** — `buildIndex(from:)`
///   - Files < `foundationThreshold` (5 MB): Foundation `JSONSerialization` walk.
///     Keys and scalar values are captured eagerly into each `IndexEntry`.
///   - Files ≥ `foundationThreshold`: simdjson C bridge for speed.
///     `IndexEntry.key` and `.parsedValue` are `nil`; values are resolved lazily in Phase 2.
///
/// **Phase 2** — `parseValue(entry:from:)`
///   Called on-demand when a node becomes visible. Slices the mapped bytes and parses
///   with Foundation.
public actor JSONParser: StructParser {

    public static let supportedExtensions: Set<String> = ["json", "jsonl"]

    /// Files below this threshold use the Foundation path (eager keys + values).
    static let foundationThreshold: UInt64 = 5 * 1024 * 1024  // 5 MB

    public init() {}

    // MARK: - Phase 1

    public func buildIndex(from file: MappedFile) async throws -> StructuralIndex {
        if file.fileSize < JSONParser.foundationThreshold {
            return try buildIndexFoundation(file: file)
        } else {
            return try buildIndexSimdjson(file: file)
        }
    }

    // MARK: - Progressive streaming

    public nonisolated func parseProgressively(file: MappedFile) -> AsyncStream<ParseProgress> {
        AsyncStream { continuation in
            Task {
                do {
                    let parser = JSONParser()
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
                    if !batch.isEmpty {
                        continuation.yield(.nodesIndexed(batch))
                    }
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

        if entry.nodeType == .object || entry.nodeType == .array {
            return .container(childCount: Int(entry.childCount))
        }

        if entry.nodeType == .keyValue {
            return .unparsed  // value lives in the child node
        }

        guard entry.byteLength > 0 else { return .unparsed }
        let raw = try file.data(offset: entry.byteOffset, length: entry.byteLength)
        let any = try JSONSerialization.jsonObject(with: raw, options: [.allowFragments])
        return .scalar(scalarValue(from: any))
    }

    // MARK: - Serialize

    public nonisolated func serialize(value: NodeValue) throws -> Data {
        switch value {
        case .scalar(let sv):
            let obj = anyValue(from: sv)
            return try JSONSerialization.data(withJSONObject: obj,
                                              options: [.fragmentsAllowed])
        case .container:
            throw JSONParserError.cannotSerializeContainer
        case .unparsed, .error:
            throw JSONParserError.noValueToSerialize
        }
    }

    // MARK: - Validate

    public func validate(file: MappedFile) async throws -> [ValidationIssue] {
        let length = UInt32(min(file.fileSize, UInt64(UInt32.max)))
        let raw = try file.data(offset: 0, length: length)
        do {
            _ = try JSONSerialization.jsonObject(with: raw, options: [.allowFragments])
            return []
        } catch let err as NSError {
            let offset = (err.userInfo["NSJSONSerializationErrorIndex"] as? UInt64) ?? 0
            return [ValidationIssue(severity: .error,
                                    message: err.localizedDescription,
                                    byteOffset: offset)]
        }
    }
}

// MARK: - Foundation path

private extension JSONParser {

    func buildIndexFoundation(file: MappedFile) throws -> StructuralIndex {
        let raw = try file.data(offset: 0, length: UInt32(file.fileSize))
        let root = try JSONSerialization.jsonObject(with: raw,
                                                    options: [.allowFragments])
        var entries: [IndexEntry] = []
        entries.reserveCapacity(256)
        walkFoundation(any: root, parentID: nil, depth: 0, key: nil, entries: &entries)
        return StructuralIndex(entries: entries)
    }

    func walkFoundation(any: Any,
                        parentID: NodeID?,
                        depth: UInt16,
                        key: String?,
                        entries: inout [IndexEntry]) {
        switch any {
        case let dict as NSDictionary:
            // Cast to NSDictionary (not [String: Any]) so we preserve the
            // insertion order that Foundation records when parsing JSON left-to-right.
            // Bridging to [String: Any] loses order because Swift Dictionary is
            // an unordered hash table.
            let nodeID = NodeID.generate()
            entries.append(IndexEntry(
                id: nodeID,
                nodeType: .object,
                depth: depth,
                parentID: parentID,
                childCount: UInt32(dict.count),
                key: key
            ))
            for k in dict.allKeys.compactMap({ $0 as? String }) {
                guard let v = dict[k] else { continue }
                walkFoundationKeyValue(key: k, value: v,
                                       parentID: nodeID, depth: depth + 1,
                                       entries: &entries)
            }

        case let arr as [Any]:
            let nodeID = NodeID.generate()
            entries.append(IndexEntry(
                id: nodeID,
                nodeType: .array,
                depth: depth,
                parentID: parentID,
                childCount: UInt32(arr.count),
                key: key
            ))
            for (i, v) in arr.enumerated() {
                walkFoundation(any: v, parentID: nodeID,
                               depth: depth + 1, key: String(i), entries: &entries)
            }

        default:
            let nodeID = NodeID.generate()
            entries.append(IndexEntry(
                id: nodeID,
                nodeType: .scalar,
                depth: depth,
                parentID: parentID,
                childCount: 0,
                key: key,
                parsedValue: scalarValue(from: any)
            ))
        }
    }

    func walkFoundationKeyValue(key: String, value: Any,
                                parentID: NodeID, depth: UInt16,
                                entries: inout [IndexEntry]) {
        let kvID = NodeID.generate()
        entries.append(IndexEntry(
            id: kvID,
            nodeType: .keyValue,
            depth: depth,
            parentID: parentID,
            childCount: 1,
            key: key
        ))
        walkFoundation(any: value, parentID: kvID,
                       depth: depth + 1, key: nil, entries: &entries)
    }
}

// MARK: - simdjson path

private extension JSONParser {

    func buildIndexSimdjson(file: MappedFile) throws -> StructuralIndex {
        // Start with a generous buffer; retry if the bridge signals MS_ERROR_BUFFER_SMALL.
        var capacity = min(max(1_024, Int(file.fileSize / 64)), 2_000_000)
        var msEntries = [MSIndexEntry](repeating: MSIndexEntry(), count: capacity)
        var count: Int64 = 0

        while true {
            msEntries = [MSIndexEntry](repeating: MSIndexEntry(), count: capacity)
            let ptr = file.rawPointer.assumingMemoryBound(to: CChar.self)
            count = ms_build_structural_index(ptr, file.fileSize,
                                              &msEntries, UInt64(capacity))
            if count == Int64(MS_ERROR_BUFFER_SMALL) {
                capacity *= 2
                continue
            }
            break
        }

        guard count >= 0 else {
            throw JSONParserError.simdjsonParseFailed(code: count)
        }

        let entries = convertBridgeEntries(Array(msEntries.prefix(Int(count))))
        return StructuralIndex(entries: entries)
    }

    /// Convert flat `MSIndexEntry` array to `IndexEntry` array.
    ///
    /// Per the bridge contract, STRING nodes whose parent is an OBJECT are key nodes.
    /// These become `.keyValue` entries; their single child holds the actual value.
    func convertBridgeEntries(_ raw: [MSIndexEntry]) -> [IndexEntry] {
        var entries = [IndexEntry]()
        entries.reserveCapacity(raw.count)

        // Index → NodeID mapping built as we go (entries are in document order).
        var idMap = [Int: NodeID]()
        idMap.reserveCapacity(raw.count)

        for (i, ms) in raw.enumerated() {
            let nodeID = NodeID.generate()
            idMap[i] = nodeID

            let parentID: NodeID? = ms.parent_index >= 0
                ? idMap[Int(ms.parent_index)]
                : nil

            // STRING nodes directly parented to an OBJECT are key nodes (.keyValue).
            let isKey = Int32(ms.node_type) == MS_NODE_TYPE_STRING
                        && ms.parent_index >= 0
                        && Int32(raw[Int(ms.parent_index)].node_type) == MS_NODE_TYPE_OBJECT

            let nodeType: NodeType
            if isKey {
                nodeType = .keyValue
            } else {
                nodeType = swiftNodeType(from: ms.node_type)
            }

            entries.append(IndexEntry(
                id: nodeID,
                byteOffset: ms.byte_offset,
                byteLength: ms.byte_length,
                nodeType: nodeType,
                depth: ms.depth,
                parentID: parentID,
                childCount: ms.child_count
                // key and parsedValue are nil — resolved lazily in Phase 2
            ))
        }

        return entries
    }

    func swiftNodeType(from raw: UInt8) -> NodeType {
        switch Int32(raw) {
        case MS_NODE_TYPE_OBJECT: return .object
        case MS_NODE_TYPE_ARRAY:  return .array
        default:                  return .scalar   // STRING, NUMBER, BOOL, NULL
        }
    }
}

// MARK: - Scalar helpers

private extension JSONParser {

    nonisolated func scalarValue(from any: Any) -> ScalarValue {
        // Must check Bool before NSNumber — Bool bridges to NSNumber in Foundation.
        if let b = any as? Bool {
            return .boolean(b)
        }
        if let n = any as? NSNumber,
           CFGetTypeID(n as CFTypeRef) != CFBooleanGetTypeID() {
            if n.doubleValue.truncatingRemainder(dividingBy: 1) == 0,
               n.doubleValue >= Double(Int64.min),
               n.doubleValue <= Double(Int64.max) {
                return .integer(n.int64Value)
            }
            return .float(n.doubleValue)
        }
        if let s = any as? String { return .string(s) }
        if any is NSNull { return .null }
        return .string(String(describing: any))
    }

    nonisolated func anyValue(from sv: ScalarValue) -> Any {
        switch sv {
        case .string(let s):  return s
        case .integer(let i): return NSNumber(value: i)
        case .float(let f):   return NSNumber(value: f)
        case .boolean(let b): return NSNumber(value: b)
        case .null:           return NSNull()
        }
    }
}

// MARK: - Errors

public enum JSONParserError: Error, Sendable {
    case simdjsonParseFailed(code: Int64)
    case cannotSerializeContainer
    case noValueToSerialize
}
