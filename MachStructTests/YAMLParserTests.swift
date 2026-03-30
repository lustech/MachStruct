import XCTest
@testable import MachStructCore

final class YAMLParserTests: XCTestCase {

    // MARK: - Helpers

    private func makeFile(yaml: String) throws -> MappedFile {
        let data = yaml.data(using: .utf8)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).yaml")
        try data.write(to: url)
        return try MappedFile(url: url)
    }

    private func buildIndex(yaml: String) async throws -> StructuralIndex {
        let file = try makeFile(yaml: yaml)
        return try await YAMLParser().buildIndex(from: file)
    }

    private func yamlMeta(_ entry: IndexEntry, file: StaticString = #file, line: UInt = #line) -> YAMLMetadata? {
        guard case .yaml(let m) = entry.metadata else {
            XCTFail("Expected .yaml metadata", file: file, line: line)
            return nil
        }
        return m
    }

    // MARK: - Basic scalars

    func testStringScalar() async throws {
        let index = try await buildIndex(yaml: "hello")
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.entries[0].nodeType, .scalar)
        XCTAssertEqual(index.entries[0].parsedValue, .string("hello"))
        XCTAssertEqual(index.entries[0].depth, 0)
        XCTAssertNil(index.entries[0].parentID)
    }

    func testIntegerScalar() async throws {
        let index = try await buildIndex(yaml: "42")
        XCTAssertEqual(index.entries[0].parsedValue, .integer(42))
    }

    func testFloatScalar() async throws {
        let index = try await buildIndex(yaml: "3.14")
        XCTAssertEqual(index.entries[0].parsedValue, .float(3.14))
    }

    func testBooleanTrueScalar() async throws {
        let index = try await buildIndex(yaml: "true")
        XCTAssertEqual(index.entries[0].parsedValue, .boolean(true))
    }

    func testBooleanFalseScalar() async throws {
        let index = try await buildIndex(yaml: "false")
        XCTAssertEqual(index.entries[0].parsedValue, .boolean(false))
    }

    func testNullTilde() async throws {
        let index = try await buildIndex(yaml: "~")
        XCTAssertEqual(index.entries[0].parsedValue, .null)
    }

    func testNullWord() async throws {
        let index = try await buildIndex(yaml: "null")
        XCTAssertEqual(index.entries[0].parsedValue, .null)
    }

    // MARK: - Quoted strings (must not be type-inferred)

    func testSingleQuotedStringKeepsType() async throws {
        // '42' → string, not integer
        let index = try await buildIndex(yaml: "'42'")
        XCTAssertEqual(index.entries[0].parsedValue, .string("42"))
        XCTAssertEqual(yamlMeta(index.entries[0])?.scalarStyle, .singleQuoted)
    }

    func testDoubleQuotedStringKeepsType() async throws {
        let index = try await buildIndex(yaml: "\"true\"")
        XCTAssertEqual(index.entries[0].parsedValue, .string("true"))
        XCTAssertEqual(yamlMeta(index.entries[0])?.scalarStyle, .doubleQuoted)
    }

    // MARK: - Flat mapping

    func testFlatMapping() async throws {
        let yaml = "name: Alice\nage: 30"
        let index = try await buildIndex(yaml: yaml)
        // mapping(obj) + kv"name" + scalar"Alice" + kv"age" + scalar(30)
        XCTAssertEqual(index.entries.count, 5)
        XCTAssertEqual(index.entries[0].nodeType, .object)
        XCTAssertEqual(index.entries[0].childCount, 2)
        XCTAssertEqual(index.entries[1].nodeType, .keyValue)
        XCTAssertEqual(index.entries[1].key, "name")
        XCTAssertEqual(index.entries[2].nodeType, .scalar)
        XCTAssertEqual(index.entries[2].parsedValue, .string("Alice"))
        XCTAssertEqual(index.entries[3].key, "age")
        XCTAssertEqual(index.entries[4].parsedValue, .integer(30))
    }

    func testMappingDepths() async throws {
        let yaml = "key: value"
        let index = try await buildIndex(yaml: yaml)
        XCTAssertEqual(index.entries[0].depth, 0)  // mapping
        XCTAssertEqual(index.entries[1].depth, 1)  // keyValue
        XCTAssertEqual(index.entries[2].depth, 2)  // scalar
    }

    func testMappingParenting() async throws {
        let yaml = "key: value"
        let index = try await buildIndex(yaml: yaml)
        let mappingID = index.entries[0].id
        let kvID = index.entries[1].id
        XCTAssertNil(index.entries[0].parentID)
        XCTAssertEqual(index.entries[1].parentID, mappingID)
        XCTAssertEqual(index.entries[2].parentID, kvID)
    }

    // MARK: - Sequence

    func testFlatSequence() async throws {
        let yaml = "- 1\n- 2\n- 3"
        let index = try await buildIndex(yaml: yaml)
        // array + 3 scalars = 4
        XCTAssertEqual(index.entries.count, 4)
        XCTAssertEqual(index.entries[0].nodeType, .array)
        XCTAssertEqual(index.entries[0].childCount, 3)
        XCTAssertEqual(index.entries[1].nodeType, .scalar)
        XCTAssertEqual(index.entries[1].key, "0")
        XCTAssertEqual(index.entries[1].parsedValue, .integer(1))
        XCTAssertEqual(index.entries[2].key, "1")
        XCTAssertEqual(index.entries[3].key, "2")
    }

    func testSequenceParenting() async throws {
        let yaml = "- a\n- b"
        let index = try await buildIndex(yaml: yaml)
        let arrID = index.entries[0].id
        XCTAssertEqual(index.entries[1].parentID, arrID)
        XCTAssertEqual(index.entries[2].parentID, arrID)
    }

    // MARK: - Nested structures

    func testNestedMapping() async throws {
        let yaml = "outer:\n  inner: value"
        let index = try await buildIndex(yaml: yaml)
        // root mapping(1 kv) → kv"outer" → inner mapping(1 kv) → kv"inner" → scalar"value"
        XCTAssertEqual(index.entries.count, 5)
        XCTAssertEqual(index.entries[0].nodeType, .object)
        XCTAssertEqual(index.entries[1].nodeType, .keyValue)
        XCTAssertEqual(index.entries[1].key, "outer")
        XCTAssertEqual(index.entries[2].nodeType, .object)   // inner mapping
        XCTAssertEqual(index.entries[3].nodeType, .keyValue)
        XCTAssertEqual(index.entries[3].key, "inner")
        XCTAssertEqual(index.entries[4].parsedValue, .string("value"))
    }

    func testSequenceOfMappings() async throws {
        let yaml = "- name: Alice\n  age: 30\n- name: Bob\n  age: 25"
        let index = try await buildIndex(yaml: yaml)
        XCTAssertEqual(index.entries[0].nodeType, .array)
        XCTAssertEqual(index.entries[0].childCount, 2)
        // First item is a mapping with 2 keys
        XCTAssertEqual(index.entries[1].nodeType, .object)
        XCTAssertEqual(index.entries[1].childCount, 2)
    }

    // MARK: - Scalar styles

    func testLiteralBlockStyle() async throws {
        let yaml = "text: |\n  line1\n  line2\n"
        let index = try await buildIndex(yaml: yaml)
        let scalar = index.entries.first { $0.nodeType == .scalar }!
        XCTAssertEqual(yamlMeta(scalar)?.scalarStyle, .literal)
        // Literal block preserves newlines
        if case .string(let s) = scalar.parsedValue {
            XCTAssert(s.contains("line1"))
            XCTAssert(s.contains("line2"))
        } else {
            XCTFail("Expected string value")
        }
    }

    func testFoldedBlockStyle() async throws {
        let yaml = "text: >\n  folded line\n"
        let index = try await buildIndex(yaml: yaml)
        let scalar = index.entries.first { $0.nodeType == .scalar }!
        XCTAssertEqual(yamlMeta(scalar)?.scalarStyle, .folded)
    }

    func testPlainStyle() async throws {
        let index = try await buildIndex(yaml: "hello")
        XCTAssertEqual(yamlMeta(index.entries[0])?.scalarStyle, .plain)
    }

    // MARK: - YAML anchors

    func testAliasResolved() async throws {
        // Yams resolves *alias to the anchored node's content before we walk the tree.
        // The alias "child" ends up with the same value structure as "base".
        // Note: Yams stores anchor info as weak refs; they are nil after compose() returns.
        let yaml = "base: &anchor\n  key: value\nchild: *anchor\n"
        let index = try await buildIndex(yaml: yaml)
        let nodeIndex = index.buildNodeIndex()

        // Both "base" and "child" should resolve to the same structure: a mapping with key "key"
        let root = nodeIndex.node(for: nodeIndex.rootID)!
        let rootChildren = nodeIndex.children(of: root.id)
        XCTAssertEqual(rootChildren.count, 2)  // two keyValue nodes: base, child

        let baseKV = rootChildren.first { $0.key == "base" }!
        let childKV = rootChildren.first { $0.key == "child" }!

        // Both should have an object child (the resolved mapping)
        let baseValue = nodeIndex.children(of: baseKV.id).first!
        let childValue = nodeIndex.children(of: childKV.id).first!
        XCTAssertEqual(baseValue.type, .object)
        XCTAssertEqual(childValue.type, .object)
    }

    // MARK: - Special YAML booleans

    func testYesIsTrue() async throws {
        let index = try await buildIndex(yaml: "yes")
        XCTAssertEqual(index.entries[0].parsedValue, .boolean(true))
    }

    func testNoIsFalse() async throws {
        let index = try await buildIndex(yaml: "no")
        XCTAssertEqual(index.entries[0].parsedValue, .boolean(false))
    }

    // MARK: - Empty / blank document

    func testEmptyDocument() async throws {
        // MappedFile cannot mmap a 0-byte file; the parser handles this case before
        // calling file.data() by checking fileSize == 0 in buildIndex.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).yaml")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        // MappedFile will throw for a truly empty file — that's expected OS behavior.
        // The meaningful "empty YAML" test is the whitespace-only case below.
        XCTAssertThrowsError(try MappedFile(url: url))
    }

    func testWhitespaceOnlyDocument() async throws {
        // Whitespace/newline-only YAML composes to nil → returns empty root node.
        let index = try await buildIndex(yaml: "   \n  \n")
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.entries[0].nodeType, .object)
        XCTAssertEqual(index.entries[0].childCount, 0)
    }

    // MARK: - NodeIndex integration

    func testBuildNodeIndex() async throws {
        let yaml = "name: Alice\nscores:\n  - 10\n  - 20"
        let file = try makeFile(yaml: yaml)
        let structural = try await YAMLParser().buildIndex(from: file)
        let nodeIndex = structural.buildNodeIndex()

        let root = nodeIndex.node(for: nodeIndex.rootID)!
        XCTAssertEqual(root.type, .object)
        let children = nodeIndex.children(of: nodeIndex.rootID)
        XCTAssertEqual(children.count, 2)

        let nameKV = children.first { $0.key == "name" }!
        XCTAssertEqual(nameKV.type, .keyValue)
    }

    func testYAMLMetadataPropagatestoDocumentNode() async throws {
        let yaml = "'hello'"
        let file = try makeFile(yaml: yaml)
        let structural = try await YAMLParser().buildIndex(from: file)
        let nodeIndex = structural.buildNodeIndex()
        let root = nodeIndex.node(for: nodeIndex.rootID)!
        if case .yaml(let meta) = root.metadata {
            XCTAssertEqual(meta.scalarStyle, .singleQuoted)
        } else {
            XCTFail("Expected YAML metadata on root DocumentNode")
        }
    }

    // MARK: - parseValue

    func testParseValueScalar() throws {
        let parser = YAMLParser()
        let entry = IndexEntry(id: .generate(), nodeType: .scalar, depth: 0, parentID: nil,
                               parsedValue: .integer(42))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dummy.yaml")
        try "42".data(using: .utf8)!.write(to: tmp)
        let file = try MappedFile(url: tmp)
        let value = try parser.parseValue(entry: entry, from: file)
        XCTAssertEqual(value, .scalar(.integer(42)))
    }

    func testParseValueContainer() throws {
        let parser = YAMLParser()
        let entry = IndexEntry(id: .generate(), nodeType: .object, depth: 0, parentID: nil,
                               childCount: 2)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dummy2.yaml")
        try "{}".data(using: .utf8)!.write(to: tmp)
        let file = try MappedFile(url: tmp)
        let value = try parser.parseValue(entry: entry, from: file)
        XCTAssertEqual(value, .container(childCount: 2))
    }

    // MARK: - Serialize

    func testSerializeString() throws {
        let parser = YAMLParser()
        let data = try parser.serialize(value: .scalar(.string("hello")))
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello")
    }

    func testSerializeStringQuotesSpecialValues() throws {
        let parser = YAMLParser()
        // "true" should be quoted so it doesn't round-trip as boolean
        let data = try parser.serialize(value: .scalar(.string("true")))
        let result = String(data: data, encoding: .utf8)!
        XCTAssertTrue(result.hasPrefix("'") || result.hasPrefix("\""),
                      "String 'true' must be quoted, got: \(result)")
    }

    func testSerializeInteger() throws {
        let parser = YAMLParser()
        let data = try parser.serialize(value: .scalar(.integer(42)))
        XCTAssertEqual(String(data: data, encoding: .utf8), "42")
    }

    func testSerializeBoolean() throws {
        let parser = YAMLParser()
        let data = try parser.serialize(value: .scalar(.boolean(true)))
        XCTAssertEqual(String(data: data, encoding: .utf8), "true")
    }

    func testSerializeNull() throws {
        let parser = YAMLParser()
        let data = try parser.serialize(value: .scalar(.null))
        XCTAssertEqual(String(data: data, encoding: .utf8), "~")
    }

    func testSerializeInfinity() throws {
        let parser = YAMLParser()
        let data = try parser.serialize(value: .scalar(.float(.infinity)))
        XCTAssertEqual(String(data: data, encoding: .utf8), ".inf")
    }

    func testSerializeNaN() throws {
        let parser = YAMLParser()
        let data = try parser.serialize(value: .scalar(.float(.nan)))
        XCTAssertEqual(String(data: data, encoding: .utf8), ".nan")
    }

    func testSerializeContainerThrows() {
        let parser = YAMLParser()
        XCTAssertThrowsError(try parser.serialize(value: .container(childCount: 1)))
    }

    // MARK: - Validation

    func testValidYAML() async throws {
        let file = try makeFile(yaml: "key: value\nlist:\n  - 1\n  - 2")
        let issues = try await YAMLParser().validate(file: file)
        XCTAssertTrue(issues.isEmpty)
    }

    func testInvalidYAMLReportsError() async throws {
        let file = try makeFile(yaml: "key: :\n  bad: [unterminated")
        let issues = try await YAMLParser().validate(file: file)
        XCTAssertFalse(issues.isEmpty)
        XCTAssertEqual(issues[0].severity, .error)
    }

    // MARK: - Progressive streaming

    func testProgressiveStreamCompletesAndEmitsBatches() async throws {
        let items = (1...50).map { "item\($0): value\($0)" }.joined(separator: "\n")
        let file = try makeFile(yaml: items)

        var batchCount = 0
        var didComplete = false

        for await progress in YAMLParser().parseProgressively(file: file) {
            switch progress {
            case .nodesIndexed: batchCount += 1
            case .complete:     didComplete = true
            case .error(let e): XCTFail("Unexpected error: \(e)")
            case .warning:      break
            }
        }

        XCTAssertTrue(didComplete)
        XCTAssertGreaterThan(batchCount, 0)
    }

    // MARK: - Supported extensions

    func testSupportedExtensions() {
        XCTAssertTrue(YAMLParser.supportedExtensions.contains("yaml"))
        XCTAssertTrue(YAMLParser.supportedExtensions.contains("yml"))
    }
}
