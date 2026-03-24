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
        // {\"name\":\"Alice\",\"age\":30}
        // entries: root(obj), kv"age", 30, kv"name", "Alice"  (sorted keys)
        let index = try await buildIndex(json: #"{"name":"Alice","age":30}"#)
        XCTAssertEqual(index.entries.count, 5)
        // Root
        XCTAssertEqual(index.entries[0].nodeType, .object)
        XCTAssertEqual(index.entries[0].childCount, 2)
        // Keys are sorted, so first kv should be "age"
        XCTAssertEqual(index.entries[1].nodeType, .keyValue)
        XCTAssertEqual(index.entries[1].key, "age")
        XCTAssertEqual(index.entries[1].depth, 1)
        XCTAssertEqual(index.entries[2].nodeType, .scalar)
        XCTAssertEqual(index.entries[2].parsedValue, .integer(30))
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
