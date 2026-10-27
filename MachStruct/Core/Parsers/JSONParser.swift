import Foundation
import CSimdjsonBridge

// MARK: - JSONParser

/// Two-phase JSON parser.
///
/// **Phase 1** — `buildIndex(from:)`
///   Structure always comes from the simdjson C bridge, which walks the byte
///   stream and therefore preserves document order and repeated keys. Routing
///   objects through `JSONSerialization`/`NSDictionary` lost both (#13, #15),
///   so the Foundation walk remains only as a fallback for documents whose
///   nesting defeats the bridge's depth cap.
///   - Files < `eagerResolveThreshold` (5 MB): `IndexEntry.key` and
///     `.parsedValue` are resolved eagerly from the mapped bytes.
///   - Files ≥ `eagerResolveThreshold`: both are `nil` and resolve lazily in
///     Phase 2, so opening a large file never touches every node.
///
/// **Phase 2** — `parseValue(entry:from:)`
///   Called on-demand when a node becomes visible. Slices the mapped bytes and parses
///   with Foundation.
public actor JSONParser: StructParser {

    public static let supportedExtensions: Set<String> = ["json", "jsonl"]

    /// Files below this threshold get their keys and scalar values resolved
    /// eagerly at index-build time; larger files resolve them lazily as nodes
    /// are materialised.
    static let eagerResolveThreshold: UInt64 = 5 * 1024 * 1024  // 5 MB

    /// Maximum nesting depth accepted on the Foundation path.
    /// `JSONSerialization` recurses per object level and overflows a 512 KB
    /// task stack somewhere past ~700 levels; 512 leaves generous margin and
    /// matches the cap common JSON implementations use.
    static let maxFoundationNestingDepth = 512

    public init() {}

    // MARK: - Phase 1

    public func buildIndex(from file: MappedFile) async throws -> StructuralIndex {
        // The simdjson walk reads the byte stream directly, so it preserves
        // document order and repeated keys. `JSONSerialization` routes objects
        // through `NSDictionary`, which silently discards both (#13, #15), so
        // the Foundation walk survives only as a fallback for documents the
        // bridge's depth cap cannot handle.
        try buildIndexSimdjson(file: file)
    }

    // MARK: - Progressive streaming

    public nonisolated func parseProgressively(file: MappedFile) -> AsyncStream<ParseProgress> {
        ParseProgress.stream { try await JSONParser().buildIndex(from: file) }
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

    /// Decode the quoted key token of a `.keyValue` entry.
    nonisolated static func decodeKeyToken(at range: (offset: UInt64, length: UInt32),
                                           in file: MappedFile) -> String? {
        guard let bytes = try? file.slice(offset: range.offset,
                                          length: range.length) else { return nil }
        return decodeStringToken(bytes)
    }

    /// Decode a scalar token (`"s"`, `1.0`, `true`, `null`) to a `ScalarValue`.
    nonisolated static func decodeScalarToken(at range: (offset: UInt64, length: UInt32),
                                              in file: MappedFile) -> ScalarValue? {
        guard let raw = try? file.data(offset: range.offset, length: range.length),
              let any = try? JSONSerialization.jsonObject(with: raw,
                                                          options: .allowFragments)
        else { return nil }
        return ScalarValue(jsonAny: any)
    }

    /// Decode a valid scalar token (`"s"`, `1.0`, `true`, `null`).
    ///
    /// Gives the same value as `decodeScalarToken`, which goes through
    /// `JSONSerialization`, but decodes strings, literals and in-range numbers
    /// itself: large files decode millions of these.
    public nonisolated static func decodeScalarBytes(_ bytes: UnsafeRawBufferPointer) -> ScalarValue? {
        guard let first = bytes.first else { return nil }
        switch first {
        case UInt8(ascii: "\""):
            return decodeStringToken(bytes).map(ScalarValue.string)
        case UInt8(ascii: "t"): return .boolean(true)
        case UInt8(ascii: "f"): return .boolean(false)
        case UInt8(ascii: "n"): return .null
        default:
            break
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let isInteger = !bytes.contains { $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "e")
                                          || $0 == UInt8(ascii: "E") }
        if isInteger {
            if let n = Int64(text) { return .integer(n) }
        } else if let d = Double(text), d.isFinite {
            return .float(d)
        }
        // Integers beyond Int64 and out-of-range floats: match Foundation.
        guard let any = try? JSONSerialization.jsonObject(with: Data(bytes),
                                                          options: .allowFragments)
        else { return nil }
        return ScalarValue(jsonAny: any)
    }

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
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: raw, options: [.allowFragments])
        } catch let error as NSError {
            throw JSONParser.parseError(from: error, in: buffer)
        }
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

// MARK: - Parse errors

extension JSONParser {

    /// Foundation's error, restated as a `ParseError`.
    ///
    /// The problem text comes from `NSDebugDescription` ("Badly formed object
    /// around line 3, column 2."); its position is replaced by one computed
    /// from the byte index, because Foundation counts columns from 0.
    static func parseError(from error: NSError,
                           in source: UnsafeRawBufferPointer) -> ParseError {
        var problem = (error.userInfo[NSDebugDescriptionErrorKey] as? String)
            ?? "The file isn't valid JSON"
        if let position = problem.range(of: #"\s*around line \d+, column \d+\.?$"#,
                                         options: .regularExpression) {
            problem.removeSubrange(position)
        }
        guard let index = error.userInfo["NSJSONSerializationErrorIndex"] as? Int else {
            return ParseError(problem: problem)
        }
        return ParseError(problem: problem, byteOffset: index, in: source)
    }
}

// MARK: - simdjson path

private extension JSONParser {

    func buildIndexSimdjson(file: MappedFile) throws -> StructuralIndex {
        // The bridge sizes its own output, so the file is parsed once. With a
        // caller-sized buffer, a large file was parsed up to five times while
        // the buffer doubled, with a buffer of up to twice the size needed (#62).
        var raw: UnsafeMutablePointer<MSIndexEntry>?
        let count = ms_build_structural_index_alloc(
            file.rawPointer.assumingMemoryBound(to: CChar.self), file.fileSize, &raw)
        defer { ms_free_entries(raw) }

        guard count >= 0, let raw else {
            // simdjson refuses some documents that are perfectly valid JSON —
            // most notably integer literals beyond UInt64.max, which it reports
            // as a parse error for the whole file (#25). Before giving up, try
            // the Foundation walk, which accepts them and degrades such values
            // to Double.
            //
            // Trade-off: the Foundation walk cannot preserve key order or
            // repeated keys (#13, #15), so a document rescued here is shown
            // with its object keys reordered. Opening it imperfectly beats
            // refusing to open it, but it is the reason this is a fallback
            // rather than the primary path.
            //
            // Foundation's error is surfaced when it also fails, because it
            // reports a position and simdjson's bare code does not.
            return try buildIndexFoundation(file: file)
        }

        // The DOM bridge cannot report token positions, so align source byte
        // ranges to the entries with one linear scan over the raw bytes.
        let rawEntries = UnsafeBufferPointer(start: raw, count: Int(count))
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
        // Small files historically carried eagerly-parsed keys and values on
        // the entries themselves; Core consumers (schema inference, tabular
        // detection) still rely on that, so resolve them here rather than
        // deferring to the app layer.
        let eager = file.fileSize < JSONParser.eagerResolveThreshold
        let entries = convertBridgeEntries(rawEntries, ranges: ranges,
                                           resolvingFrom: eager ? file : nil)
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
    func convertBridgeEntries(_ raw: UnsafeBufferPointer<MSIndexEntry>,
                              ranges: [(offset: UInt64, length: UInt32)],
                              resolvingFrom file: MappedFile?) -> [IndexEntry] {
        var entries = [IndexEntry]()
        entries.reserveCapacity(raw.count)

        // Entry `i` gets ID `base + i`, so a parent index maps to its ID by
        // arithmetic, without a dictionary the size of the document.
        let base = NodeID.reserveBlock(count: raw.count)

        // Position of each array element among its siblings. The Foundation
        // walk used to store these as the element's key ("0", "1", …), and
        // the eager path still does; paths use the element's position.
        var arrayOrdinal = [Int: Int]()

        for (i, ms) in raw.enumerated() {
            let nodeID = NodeID(rawValue: base + UInt64(i))
            let parentID: NodeID? = ms.parent_index >= 0
                ? NodeID(rawValue: base + UInt64(ms.parent_index))
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

            // Resolved now for small files, left nil for large ones (Phase 2
            // materialisation fills them in as the user expands nodes).
            var key: String?
            var parsedValue: ScalarValue?
            if file != nil, ms.parent_index >= 0,
               Int32(raw[Int(ms.parent_index)].node_type) == MS_NODE_TYPE_ARRAY {
                let parent = Int(ms.parent_index)
                let ordinal = arrayOrdinal[parent, default: 0]
                arrayOrdinal[parent] = ordinal + 1
                key = String(ordinal)
            }
            if let file, ranges[i].length > 0 {
                switch nodeType {
                case .keyValue:
                    key = JSONParser.decodeKeyToken(at: ranges[i], in: file)
                case .scalar:
                    parsedValue = JSONParser.decodeScalarToken(at: ranges[i], in: file)
                default:
                    break
                }
            }

            entries.append(IndexEntry(
                id: nodeID,
                byteOffset: ranges[i].offset,
                byteLength: ranges[i].length,
                nodeType: nodeType,
                depth: ms.depth,
                parentID: parentID,
                childCount: ms.child_count,
                key: key,
                parsedValue: parsedValue
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
    case cannotSerializeContainer
    case noValueToSerialize
    case nestingTooDeep(limit: Int)
    case fileTooLargeForEagerParse(bytes: UInt64)

    public var errorDescription: String? {
        switch self {
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
