import XCTest
@testable import MachStructCore

final class JSONParserTests: XCTestCase {

    // MARK: - Helpers

    private func makeFile(json: String) throws -> MappedFile {
        let data = json.data(using: .utf8)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).json")
        try data.write(to: url)
        return try MappedFile(url: url)
    }

    private func buildIndex(json: String) async throws -> StructuralIndex {
        let file = try makeFile(json: json)
        let parser = JSONParser()
        return try await parser.buildIndex(from: file)
    }

    // MARK: - simdjson path: byte ranges (P1-06)

    /// On the simdjson path every entry must carry a real byte range so
    /// Phase 2 can lazily parse keys and values from the mapped file.
    /// (Regression: the bridge left `byte_offset = 0` everywhere, so keys and
    /// values on ≥ 5 MB files resolved to garbage or stayed `.unparsed`.)
    func testSimdjsonPathRecordsUsableByteRanges() async throws {
        var rows: [String] = []
        for i in 0..<80_000 {
            rows.append(#"{"idx":\#(i),"label":"row \#(i)","flag":true,"#
                        + #""ratio":0.25,"note":null,"esc":"a\"b\#(i)"}"#)
        }
        let json = "[\n" + rows.joined(separator: ",\n") + "\n]"
        XCTAssertGreaterThan(UInt64(json.utf8.count), JSONParser.foundationThreshold)

        let file = try makeFile(json: json)
        let parser = JSONParser()
        let index = try await parser.buildIndex(from: file)

        // Confirm simdjson path (keys are lazy).
        let kvEntries = index.entries.filter { $0.nodeType == .keyValue }
        XCTAssertNil(kvEntries.first?.key)

        // 1. Every scalar and keyValue entry has a byte range.
        // (Count violations rather than asserting per entry — a regression
        // would otherwise record millions of XCTest failures.)
        let missingRanges = index.entries.reduce(into: 0) { count, entry in
            if entry.nodeType == .scalar || entry.nodeType == .keyValue,
               entry.byteOffset == 0 || entry.byteLength == 0 {
                count += 1
            }
        }
        XCTAssertEqual(missingRanges, 0,
                       "\(missingRanges) scalar/keyValue entries lack byte ranges")

        // 2. Keys decode from their byte ranges (first object's fields).
        let root = index.entries[0]
        let firstObjIdx = try XCTUnwrap(index.childIndices[root.id]?.first)
        let firstObj = index.entries[firstObjIdx]
        let keyIdxs = try XCTUnwrap(index.childIndices[firstObj.id])
        let keys = try keyIdxs.map { kvIdx -> String in
            let kv = index.entries[kvIdx]
            let raw = try file.data(offset: kv.byteOffset, length: kv.byteLength)
            let decoded = try JSONSerialization.jsonObject(with: raw,
                                                           options: .allowFragments)
            return try XCTUnwrap(decoded as? String)
        }
        XCTAssertEqual(keys, ["idx", "label", "flag", "ratio", "note", "esc"])

        // 3. Values parse via Phase 2 with correct types.
        func phase2Value(key: String) throws -> NodeValue {
            let kvIdx = try XCTUnwrap(keyIdxs.first { idx in
                let kv = index.entries[idx]
                let raw = try? file.data(offset: kv.byteOffset, length: kv.byteLength)
                let s = raw.flatMap {
                    try? JSONSerialization.jsonObject(with: $0,
                                                      options: .allowFragments) as? String
                }
                return s == key
            })
            let valIdx = try XCTUnwrap(index.childIndices[index.entries[kvIdx].id]?.first)
            return try parser.parseValue(entry: index.entries[valIdx], from: file)
        }
        XCTAssertEqual(try phase2Value(key: "idx"),   .scalar(.integer(0)))
        XCTAssertEqual(try phase2Value(key: "label"), .scalar(.string("row 0")))
        XCTAssertEqual(try phase2Value(key: "flag"),  .scalar(.boolean(true)))
        XCTAssertEqual(try phase2Value(key: "ratio"), .scalar(.float(0.25)))
        XCTAssertEqual(try phase2Value(key: "note"),  .scalar(.null))
        XCTAssertEqual(try phase2Value(key: "esc"),   .scalar(.string(#"a"b0"#)))

        // 4. Containers span their full source range.
        XCTAssertEqual(root.byteOffset, 0)
        XCTAssertEqual(UInt64(root.byteLength), UInt64(json.utf8.count))

        // 5. Key search works end-to-end on the lazy path.
        let matches = SearchEngine.search(query: "ratio", in: index, file: file)
        XCTAssertEqual(matches.count, 80_000)
    }

    /// Beyond the safe cap, parsing must fail with a thrown error — never a
    /// stack overflow. (Foundation's JSONSerialization recurses per nesting
    /// level with no depth guard; ~700+ levels overflow a 512 KB task stack.)
    func testExtremeNestingThrowsCleanError() async throws {
        // Object chains are the dangerous shape: Foundation rejects deep
        // arrays with an error but recurses (and crashes) on deep objects.
        let depth = 2_000
        let json = String(repeating: #"{"a":"#, count: depth) + "1"
            + String(repeating: "}", count: depth)
        let file = try makeFile(json: json)
        do {
            _ = try await JSONParser().buildIndex(from: file)
            XCTFail("expected a nesting-depth error")
        } catch {
            // Clean error is the required outcome.
        }
    }

    // MARK: - Token scanner alignment guard

    /// When tokens and entries disagree, the scanner must refuse (nil) rather
    /// than mis-assign ranges.
    func testScanTokenRangesRefusesOnCountMismatch() {
        let json = Array(#"{"a":1}"#.utf8)
        json.withUnsafeBytes { buf in
            // Correct count: root + kv + scalar = 3.
            XCTAssertNotNil(JSONParser.scanTokenRanges(buffer: buf, entryCount: 3))
            // Wrong counts: must refuse, not truncate or pad.
            XCTAssertNil(JSONParser.scanTokenRanges(buffer: buf, entryCount: 2))
            XCTAssertNil(JSONParser.scanTokenRanges(buffer: buf, entryCount: 4))
        }
    }

    /// Whatever path buildIndex takes, it must never produce the silent-garbage
    /// state where a keyValue entry has neither an eager key nor a usable byte
    /// range. (Files the parser cannot represent should throw instead.)
    func testNoSilentlyUnresolvableKeysOnAnyPath() async throws {
        // ≥ 5 MB with a deep chain that exceeds the bridge's depth cap (1000),
        // which forces the token scanner to detect misalignment.
        let depth = 1005
        let padding = String(repeating: "x", count: 6_000_000)
        let json = #"{"pad":"\#(padding)","deep":"#
            + String(repeating: #"{"a":"#, count: depth) + "1"
            + String(repeating: "}", count: depth) + "}"
        let file = try makeFile(json: json)
        do {
            let si = try await JSONParser().buildIndex(from: file)
            let unresolvable = si.entries.reduce(into: 0) { count, entry in
                if entry.nodeType == .keyValue,
                   entry.key == nil, entry.byteLength == 0 {
                    count += 1
                }
            }
            XCTAssertEqual(unresolvable, 0,
                "\(unresolvable) keyValue entries have neither key nor byte range")
        } catch {
            // An explicit error is an acceptable outcome; silent garbage is not.
        }
    }

    // MARK: - Deep nesting (stack safety)

    /// Parsing must not recurse per nesting level: Swift Concurrency threads
    /// have 512 KB stacks, and a recursive walk overflows (SIGBUS) at roughly
    /// 200 levels — crashing the app on pathological-but-valid files.
    func testDeeplyNestedJSONDoesNotOverflowStack() async throws {
        let depth = 400
        let json = String(repeating: #"{"a":"#, count: depth) + "1"
            + String(repeating: "}", count: depth)
        let index = try await buildIndex(json: json)
        let maxDepth = index.entries.map { Int($0.depth) }.max() ?? 0
        XCTAssertGreaterThanOrEqual(maxDepth, depth,
            "expected \(depth)+ levels, got \(maxDepth)")
    }

    // MARK: - Foundation path: structure

    func testEmptyObjectFoundation() async throws {
        let index = try await buildIndex(json: "{}")
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.entries[0].nodeType, .object)
        XCTAssertEqual(index.entries[0].childCount, 0)
        XCTAssertNil(index.entries[0].parentID)
        XCTAssertEqual(index.entries[0].depth, 0)
    }

    func testEmptyArrayFoundation() async throws {
        let index = try await buildIndex(json: "[]")
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.entries[0].nodeType, .array)
        XCTAssertEqual(index.entries[0].childCount, 0)
    }

    func testFlatObjectFoundation() async throws {
        // {"name":"Alice","age":30}
        // Foundation path preserves document (insertion) order via NSDictionary.
        // entries: root(obj), kv"name", "Alice", kv"age", 30
        let index = try await buildIndex(json: #"{"name":"Alice","age":30}"#)
        XCTAssertEqual(index.entries.count, 5)
        // Root
        XCTAssertEqual(index.entries[0].nodeType, .object)
        XCTAssertEqual(index.entries[0].childCount, 2)
        // First kv is "name" (document order)
        XCTAssertEqual(index.entries[1].nodeType, .keyValue)
        XCTAssertEqual(index.entries[1].key, "name")
        XCTAssertEqual(index.entries[1].depth, 1)
        XCTAssertEqual(index.entries[2].nodeType, .scalar)
        XCTAssertEqual(index.entries[2].parsedValue, .string("Alice"))
    }

    func testFlatArrayFoundation() async throws {
        let index = try await buildIndex(json: "[1,2,3]")
        XCTAssertEqual(index.entries.count, 4)
        XCTAssertEqual(index.entries[0].nodeType, .array)
        XCTAssertEqual(index.entries[0].childCount, 3)
        XCTAssertEqual(index.entries[1].nodeType, .scalar)
        XCTAssertEqual(index.entries[1].key, "0")
    }

    func testScalarTypes() async throws {
        let json = #"{"s":"hello","n":42,"f":3.14,"b":true,"nil":null}"#
        let index = try await buildIndex(json: json)
        let scalars = index.entries.filter { $0.nodeType == .scalar }
        let values = scalars.compactMap { $0.parsedValue }
        XCTAssert(values.contains(.string("hello")))
        XCTAssert(values.contains(.integer(42)))
        XCTAssert(values.contains(.float(3.14)))
        XCTAssert(values.contains(.boolean(true)))
        XCTAssert(values.contains(.null))
    }

    func testNestedObject() async throws {
        let json = #"{"outer":{"inner":"value"}}"#
        let index = try await buildIndex(json: json)
        XCTAssertFalse(index.entries.isEmpty)
        let maxDepth = index.entries.map { Int($0.depth) }.max() ?? 0
        XCTAssertGreaterThanOrEqual(maxDepth, 3)
    }

    func testScalarRootString() async throws {
        let index = try await buildIndex(json: #""hello""#)
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.entries[0].nodeType, .scalar)
        XCTAssertEqual(index.entries[0].parsedValue, .string("hello"))
    }

    func testScalarRootNumber() async throws {
        let index = try await buildIndex(json: "42")
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.entries[0].parsedValue, .integer(42))
    }

    func testBoolNotMistakenForNumber() async throws {
        let index = try await buildIndex(json: #"{"t":true,"f":false}"#)
        let scalars = index.entries.filter { $0.nodeType == .scalar }
        let values = scalars.compactMap { $0.parsedValue }
        XCTAssert(values.contains(.boolean(true)))
        XCTAssert(values.contains(.boolean(false)))
        XCTAssertFalse(values.contains(.integer(1)))
        XCTAssertFalse(values.contains(.integer(0)))
    }

    // MARK: - NodeIndex integration

    func testBuildNodeIndexFromFoundation() async throws {
        let json = #"{"key":"value"}"#
        let si = try await buildIndex(json: json)
        let ni = si.buildNodeIndex()
        XCTAssertNotNil(ni.root)
        XCTAssertEqual(ni.root?.type, .object)
        let children = ni.children(of: ni.rootID)
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children[0].key, "key")
    }

    func testBuildNodeIndexChildIDs() async throws {
        let json = "[1,2,3]"
        let si = try await buildIndex(json: json)
        let ni = si.buildNodeIndex()
        let children = ni.children(of: ni.rootID)
        XCTAssertEqual(children.count, 3)
    }

    // MARK: - Serialize

    func testSerializeString() throws {
        let parser = JSONParser()
        let data = try parser.serialize(value: .scalar(.string("hello")))
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"hello\"")
    }

    func testSerializeInteger() throws {
        let parser = JSONParser()
        let data = try parser.serialize(value: .scalar(.integer(42)))
        XCTAssertEqual(String(data: data, encoding: .utf8), "42")
    }

    func testSerializeBool() throws {
        let parser = JSONParser()
        let data = try parser.serialize(value: .scalar(.boolean(true)))
        XCTAssertEqual(String(data: data, encoding: .utf8), "true")
    }

    func testSerializeNull() throws {
        let parser = JSONParser()
        let data = try parser.serialize(value: .scalar(.null))
        XCTAssertEqual(String(data: data, encoding: .utf8), "null")
    }

    func testSerializeContainerThrows() {
        let parser = JSONParser()
        XCTAssertThrowsError(try parser.serialize(value: .container(childCount: 3)))
    }

    // MARK: - Progressive streaming

    func testProgressiveStreamEmitsComplete() async throws {
        let file = try makeFile(json: #"{"a":1,"b":2}"#)
        let parser = JSONParser()
        var completed = false
        var nodeCount = 0
        for await progress in parser.parseProgressively(file: file) {
            switch progress {
            case .nodesIndexed(let batch): nodeCount += batch.count
            case .complete(let index): completed = true; nodeCount = index.entries.count
            case .error(let e): XCTFail("unexpected error: \(e)")
            case .warning: break
            }
        }
        XCTAssertTrue(completed)
        XCTAssertGreaterThan(nodeCount, 0)
    }

    // MARK: - Invalid JSON

    func testInvalidJSONThrows() async {
        do {
            _ = try await buildIndex(json: "{ invalid json }")
            XCTFail("Expected error")
        } catch {
            // expected
        }
    }

    func testTruncatedJSONThrows() async {
        do {
            _ = try await buildIndex(json: #"{"key":"val"#)
            XCTFail("Expected error")
        } catch {
            // expected
        }
    }

    // MARK: - Validate

    func testValidateValidJSON() async throws {
        let file = try makeFile(json: #"{"ok":true}"#)
        let parser = JSONParser()
        let issues = try await parser.validate(file: file)
        XCTAssertTrue(issues.isEmpty)
    }

    func testValidateInvalidJSON() async throws {
        let file = try makeFile(json: "{ bad }")
        let parser = JSONParser()
        let issues = try await parser.validate(file: file)
        XCTAssertFalse(issues.isEmpty)
        XCTAssertEqual(issues[0].severity, .error)
    }
}
