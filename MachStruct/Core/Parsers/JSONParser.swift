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

    /// Maximum nesting depth accepted on the Foundation path.
    /// `JSONSerialization` recurses per object level and overflows a 512 KB
    /// task stack somewhere past ~700 levels; 512 leaves generous margin and
    /// matches the cap common JSON implementations use.
    static let maxFoundationNestingDepth = 512

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
        return .scalar(ScalarValue(jsonAny: any))
    }

    // MARK: - Shared byte-token helpers

    /// Decode a raw JSON string token (including surrounding quotes).
    /// Fast path for the common no-escape case; Foundation fallback otherwise.
    ///
    /// The single implementation behind key resolution in `SearchEngine`,
    /// `StructDocument`, and `SchemaInferenceEngine`.
    public nonisolated static func decodeStringToken(_ bytes: UnsafeRawBufferPointer) -> String? {
        guard bytes.count >= 2,
              bytes[0] == UInt8(ascii: "\""),
              bytes[bytes.count - 1] == UInt8(ascii: "\"") else { return nil }
        let inner = UnsafeRawBufferPointer(rebasing: bytes[1..<(bytes.count - 1)])
        if !inner.contains(UInt8(ascii: "\\")) {
            return String(bytes: inner, encoding: .utf8)
        }
        let data = Data(bytes)
        return (try? JSONSerialization.jsonObject(with: data,
                                                  options: .allowFragments)) as? String
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
        guard file.fileSize <= UInt64(UInt32.max) else {
            throw JSONParserError.fileTooLargeForEagerParse(bytes: file.fileSize)
        }
        // JSONSerialization recurses once per nesting level with no depth
        // guard of its own for objects: past ~700 levels it overflows the
        // 512 KB Swift-Concurrency stack (SIGBUS). Refuse cleanly first.
        let buffer = UnsafeRawBufferPointer(start: file.rawPointer,
                                            count: Int(file.fileSize))
        let depth = JSONParser.measureNestingDepth(
            buffer, limit: JSONParser.maxFoundationNestingDepth)
        guard depth <= JSONParser.maxFoundationNestingDepth else {
            throw JSONParserError.nestingTooDeep(limit: JSONParser.maxFoundationNestingDepth)
        }
        let raw = try file.data(offset: 0, length: UInt32(file.fileSize))
        let root = try JSONSerialization.jsonObject(with: raw,
                                                    options: [.allowFragments])
        var entries: [IndexEntry] = []
        entries.reserveCapacity(256)
        walkFoundation(root: root, entries: &entries)
        return StructuralIndex(entries: entries)
    }

    /// DFS walk over the Foundation object graph using an explicit work stack.
    ///
    /// Must not recurse per nesting level: Swift Concurrency threads have
    /// 512 KB stacks, and a recursive walk overflows at ~200 levels of nesting
    /// on valid (if pathological) documents.
    ///
    /// Work items are pushed in reverse so entries pop in document order —
    /// NodeIDs stay contiguous, which `StructuralIndex.entryIDBase` relies on.
    func walkFoundation(root: Any, entries: inout [IndexEntry]) {
        enum Work {
            case value(Any, parentID: NodeID?, depth: UInt16, key: String?)
            case keyValue(key: String, value: Any, parentID: NodeID, depth: UInt16)
        }
        var stack: [Work] = [.value(root, parentID: nil, depth: 0, key: nil)]

        while let work = stack.popLast() {
            switch work {
            case .keyValue(let key, let value, let parentID, let depth):
                let kvID = NodeID.generate()
                entries.append(IndexEntry(
                    id: kvID,
                    nodeType: .keyValue,
                    depth: depth,
                    parentID: parentID,
                    childCount: 1,
                    key: key
                ))
                stack.append(.value(value, parentID: kvID,
                                    depth: depth + 1, key: nil))

            case .value(let any, let parentID, let depth, let key):
                switch any {
                case let dict as NSDictionary:
                    // Keep NSDictionary (not [String: Any]) to preserve the
                    // insertion order Foundation records when parsing JSON
                    // left-to-right; bridging to Swift Dictionary loses it.
                    let nodeID = NodeID.generate()
                    entries.append(IndexEntry(
                        id: nodeID,
                        nodeType: .object,
                        depth: depth,
                        parentID: parentID,
                        childCount: UInt32(dict.count),
                        key: key
                    ))
                    for k in dict.allKeys.compactMap({ $0 as? String }).reversed() {
                        guard let v = dict[k] else { continue }
                        stack.append(.keyValue(key: k, value: v,
                                               parentID: nodeID, depth: depth + 1))
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
                    for (i, v) in arr.enumerated().reversed() {
                        stack.append(.value(v, parentID: nodeID,
                                            depth: depth + 1, key: String(i)))
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
                        parsedValue: ScalarValue(jsonAny: any)
                    ))
                }
            }
        }
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

        // The DOM bridge cannot report token positions, so align source byte
        // ranges to the entries with one linear scan over the raw bytes.
        let rawEntries = Array(msEntries.prefix(Int(count)))
        let buffer = UnsafeRawBufferPointer(start: file.rawPointer,
                                            count: Int(file.fileSize))
        guard let ranges = JSONParser.scanTokenRanges(buffer: buffer,
                                                      entryCount: rawEntries.count)
        else {
            // Tokens and entries disagree — the bridge's depth cap truncated
            // the walk. Zeroed byte ranges would silently break every lazy
            // key/value read, so fall back to the (iterative, stack-safe)
            // Foundation walk when its own depth limit allows; otherwise
            // refuse with a clean error rather than crash or corrupt.
            return try buildIndexFoundation(file: file)
            // buildIndexFoundation enforces maxFoundationNestingDepth and the
            // 4 GB eager-parse ceiling itself.
        }
        let entries = convertBridgeEntries(rawEntries, ranges: ranges)
        return StructuralIndex(entries: entries)
    }
}

extension JSONParser {

    /// Assign a source byte range to every bridge entry in one linear pass.
    ///
    /// Bridge entries are in strict DFS document order — exactly the order
    /// value and key tokens appear in the source — so scanning tokens
    /// left-to-right aligns 1:1 with the entry list:
    /// - `{` / `[` opens a container entry (length patched at its close)
    /// - a string token is an object key (`.keyValue`) or string scalar
    /// - a number/`true`/`false`/`null` token is a scalar
    ///
    /// Returns `nil` when tokens and entries disagree (e.g. the bridge's
    /// depth cap truncated the walk) so callers can refuse rather than
    /// mis-assign.
    /// Measure the maximum container nesting depth of raw JSON bytes.
    /// Stops early once `limit + 1` is reached — callers only need to know
    /// whether the document is safe, not how deep it actually goes.
    nonisolated static func measureNestingDepth(_ buffer: UnsafeRawBufferPointer,
                                                limit: Int) -> Int {
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        var depth = 0, maxDepth = 0, i = 0
        let n = buffer.count
        while i < n {
            switch buffer[i] {
            case quote:
                i += 1
                while i < n, buffer[i] != quote {
                    i += buffer[i] == backslash ? 2 : 1
                }
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                if depth > maxDepth {
                    maxDepth = depth
                    if maxDepth > limit { return maxDepth }
                }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            default:
                break
            }
            i += 1
        }
        return maxDepth
    }

    nonisolated static func scanTokenRanges(buffer: UnsafeRawBufferPointer,
                                            entryCount: Int) -> [(offset: UInt64, length: UInt32)]? {
        var ranges = [(offset: UInt64, length: UInt32)](repeating: (0, 0),
                                                        count: entryCount)
        var containerStack: [Int] = []   // entry indices of open containers
        var next = 0                     // next entry index to assign
        var i = 0
        let n = buffer.count

        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        let comma = UInt8(ascii: ","), colon = UInt8(ascii: ":")
        let openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")
        let openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]")

        @inline(__always) func isWhitespace(_ c: UInt8) -> Bool {
            c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
        }

        while i < n {
            let b = buffer[i]
            switch b {
            case _ where isWhitespace(b), comma, colon:
                i += 1

            case openBrace, openBracket:
                guard next < entryCount else { return nil }
                ranges[next] = (UInt64(i), 0)
                containerStack.append(next)
                next += 1
                i += 1

            case closeBrace, closeBracket:
                guard let open = containerStack.popLast() else { return nil }
                // Container spans in >4 GiB files exceed UInt32 — degrade to
                // "range unknown" (0) instead of trapping. Leaf tokens are
                // unaffected, so lazy keys/values keep working.
                let span = UInt64(i) - ranges[open].offset + 1
                ranges[open].length = span <= UInt64(UInt32.max) ? UInt32(span) : 0
                i += 1

            case quote:
                let start = i
                i += 1
                while i < n, buffer[i] != quote {
                    i += buffer[i] == backslash ? 2 : 1
                }
                guard i < n, next < entryCount else { return nil }
                i += 1   // include the closing quote
                ranges[next] = (UInt64(start), UInt32(i - start))
                next += 1

            default:
                // number / true / false / null
                let start = i
                while i < n {
                    let c = buffer[i]
                    if isWhitespace(c) || c == comma
                        || c == closeBrace || c == closeBracket { break }
                    i += 1
                }
                guard next < entryCount else { return nil }
                ranges[next] = (UInt64(start), UInt32(i - start))
                next += 1
            }
        }

        guard next == entryCount, containerStack.isEmpty else { return nil }
        return ranges
    }

    /// Convert flat `MSIndexEntry` array to `IndexEntry` array.
    ///
    /// Per the bridge contract, STRING nodes whose parent is an OBJECT are key nodes.
    /// These become `.keyValue` entries; their single child holds the actual value.
    func convertBridgeEntries(_ raw: [MSIndexEntry],
                              ranges: [(offset: UInt64, length: UInt32)]) -> [IndexEntry] {
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
                byteOffset: ranges[i].offset,
                byteLength: ranges[i].length,
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

public enum JSONParserError: Error, Sendable, LocalizedError {
    case simdjsonParseFailed(code: Int64)
    case cannotSerializeContainer
    case noValueToSerialize
    case nestingTooDeep(limit: Int)
    case fileTooLargeForEagerParse(bytes: UInt64)

    public var errorDescription: String? {
        switch self {
        case .simdjsonParseFailed(let code):
            return "JSON parse failed (simdjson error \(code))."
        case .cannotSerializeContainer:
            return "Containers cannot be serialized as scalar values."
        case .noValueToSerialize:
            return "The node has no parsed value to serialize."
        case .nestingTooDeep(let limit):
            return "The document nests deeper than \(limit) levels, which MachStruct cannot open safely."
        case .fileTooLargeForEagerParse(let bytes):
            return "The file (\(bytes) bytes) is too large to parse eagerly."
        }
    }
}
