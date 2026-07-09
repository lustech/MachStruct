import XCTest
@testable import MachStructCore

/// Tests for X-Ray Mode schema inference (FEATURE-IDEAS #1).
///
/// Covers both engine paths:
///  - `infer(from: StructuralIndex, file:)` — linear entry scan (lazy/large files)
///  - `infer(from: NodeIndex, file:)`       — DocumentNode walk (small files)
final class SchemaInferenceTests: XCTestCase {

    // MARK: - Helpers

    private func makeFile(json: String) throws -> MappedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-test-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        return try MappedFile(url: url)
    }

    /// Foundation-path structural index (eager keys + values) for a JSON string.
    private func inferFromIndex(json: String,
                                rootID: NodeID? = nil,
                                maxDepth: Int = 100) async throws -> InferredSchema {
        let file = try makeFile(json: json)
        let si = try await JSONParser().buildIndex(from: file)
        return SchemaInferenceEngine.infer(from: si, file: file,
                                           rootID: rootID, maxDepth: maxDepth)
    }

    /// NodeIndex path (what small files retain after eager build).
    private func inferFromNodeIndex(json: String,
                                    rootID: NodeID? = nil) async throws -> InferredSchema {
        let file = try makeFile(json: json)
        let si = try await JSONParser().buildIndex(from: file)
        let idx = si.buildNodeIndex()
        return SchemaInferenceEngine.infer(from: idx, file: file, rootID: rootID)
    }

    private func field(_ key: String, in node: SchemaNode) -> SchemaField? {
        node.fields.first { $0.key == key }
    }

    // MARK: - Flat objects

    func testFlatObjectScalarKinds() async throws {
        let schema = try await inferFromIndex(
            json: #"{"s":"hello","i":42,"f":3.14,"b":true,"n":null}"#)
        let root = schema.root
        XCTAssertEqual(root.occurrences, 1)
        XCTAssertEqual(root.kindCounts[.object], 1)
        XCTAssertEqual(root.fields.count, 5)

        XCTAssertEqual(field("s", in: root)?.schema.typeSignature, "string")
        XCTAssertEqual(field("i", in: root)?.schema.typeSignature, "int")
        XCTAssertEqual(field("f", in: root)?.schema.typeSignature, "number")
        XCTAssertEqual(field("b", in: root)?.schema.typeSignature, "bool")
        XCTAssertEqual(field("n", in: root)?.schema.typeSignature, "null")
    }

    func testFieldsPreserveDocumentOrder() async throws {
        let schema = try await inferFromIndex(json: #"{"z":1,"a":2,"m":3}"#)
        XCTAssertEqual(schema.root.fields.map(\.key), ["z", "a", "m"])
    }

    func testNodesScannedCountsValueNodes() async throws {
        // root object + 2 scalar values = 3 (keyValue wrappers don't count)
        let schema = try await inferFromIndex(json: #"{"name":"Alice","age":30}"#)
        XCTAssertEqual(schema.nodesScanned, 3)
    }

    // MARK: - Arrays and merging

    func testArrayOfUniformObjects() async throws {
        let schema = try await inferFromIndex(
            json: #"[{"id":1,"name":"a"},{"id":2,"name":"b"},{"id":3,"name":"c"}]"#)
        let root = schema.root
        XCTAssertEqual(root.typeSignature, "object[]")

        let element = try XCTUnwrap(root.element)
        XCTAssertEqual(element.occurrences, 3)
        XCTAssertEqual(field("id", in: element)?.presence, 3)
        XCTAssertEqual(field("id", in: element)?.schema.typeSignature, "int")
        XCTAssertEqual(field("name", in: element)?.schema.typeSignature, "string")
        XCTAssertFalse(try XCTUnwrap(field("id", in: element)).isOptional)
    }

    func testOptionalFieldDetection() async throws {
        // "email" present in 1 of 3 objects → optional
        let schema = try await inferFromIndex(
            json: #"[{"id":1,"email":"x@y.z"},{"id":2},{"id":3}]"#)
        let element = try XCTUnwrap(schema.root.element)
        let email = try XCTUnwrap(field("email", in: element))
        XCTAssertTrue(email.isOptional)
        XCTAssertEqual(email.presence, 1)
        XCTAssertEqual(email.displaySignature, "string?")

        let id = try XCTUnwrap(field("id", in: element))
        XCTAssertFalse(id.isOptional)
        XCTAssertEqual(id.displaySignature, "int")
    }

    func testScalarArraySignature() async throws {
        let schema = try await inferFromIndex(json: #"{"tags":["a","b","c"]}"#)
        XCTAssertEqual(field("tags", in: schema.root)?.schema.typeSignature, "string[]")
    }

    func testEmptyArraySignature() async throws {
        let schema = try await inferFromIndex(json: #"{"tags":[]}"#)
        let tags = try XCTUnwrap(field("tags", in: schema.root))
        XCTAssertEqual(tags.schema.typeSignature, "array")
        XCTAssertNil(tags.schema.element)
    }

    func testEmptyObject() async throws {
        let schema = try await inferFromIndex(json: "{}")
        XCTAssertEqual(schema.root.typeSignature, "object")
        XCTAssertTrue(schema.root.fields.isEmpty)
        XCTAssertTrue(schema.inconsistencies.isEmpty)
    }

    // MARK: - Type widening and unions

    func testIntFloatWidensToNumberWithoutConflict() async throws {
        let schema = try await inferFromIndex(json: #"[{"v":1},{"v":2.5},{"v":3}]"#)
        let v = try XCTUnwrap(field("v", in: try XCTUnwrap(schema.root.element)))
        XCTAssertEqual(v.schema.typeSignature, "number")
        XCTAssertFalse(v.schema.hasKindConflict)
        XCTAssertTrue(schema.inconsistencies.isEmpty)
    }

    func testNullMakesNullableNotConflicting() async throws {
        let schema = try await inferFromIndex(json: #"[{"v":"a"},{"v":null},{"v":"b"}]"#)
        let v = try XCTUnwrap(field("v", in: try XCTUnwrap(schema.root.element)))
        XCTAssertEqual(v.schema.typeSignature, "string?")
        XCTAssertFalse(v.schema.hasKindConflict)
        XCTAssertTrue(schema.inconsistencies.isEmpty)
    }

    func testMixedKindsAreConflicting() async throws {
        // age is int in 3 records, string in 1 → conflict, dominant kind first
        let schema = try await inferFromIndex(
            json: #"[{"age":1},{"age":2},{"age":3},{"age":"four"}]"#)
        let age = try XCTUnwrap(field("age", in: try XCTUnwrap(schema.root.element)))
        XCTAssertTrue(age.schema.hasKindConflict)
        XCTAssertEqual(age.schema.typeSignature, "int | string")
        XCTAssertEqual(age.schema.kindCounts[.integer], 3)
        XCTAssertEqual(age.schema.kindCounts[.string], 1)
    }

    func testInconsistencyReportWithPathAndCounts() async throws {
        let schema = try await inferFromIndex(
            json: #"{"items":[{"age":1},{"age":2},{"age":3},{"age":"four"}]}"#)
        XCTAssertEqual(schema.inconsistencies.count, 1)
        let inc = try XCTUnwrap(schema.inconsistencies.first)
        XCTAssertEqual(inc.path, "$.items[].age")
        XCTAssertTrue(inc.message.contains("string"), "message: \(inc.message)")
        XCTAssertTrue(inc.message.contains("1 of 4"), "message: \(inc.message)")
    }

    func testContainerScalarMixConflicts() async throws {
        let schema = try await inferFromIndex(json: #"[{"v":{"x":1}},{"v":"flat"}]"#)
        let v = try XCTUnwrap(field("v", in: try XCTUnwrap(schema.root.element)))
        XCTAssertTrue(v.schema.hasKindConflict)
        XCTAssertEqual(schema.inconsistencies.count, 1)
    }

    // MARK: - Nesting

    func testNestedObjectSchema() async throws {
        let schema = try await inferFromIndex(
            json: #"{"user":{"name":"a","address":{"city":"b","zip":12345}}}"#)
        let user = try XCTUnwrap(field("user", in: schema.root))
        XCTAssertEqual(user.schema.typeSignature, "object")
        let address = try XCTUnwrap(field("address", in: user.schema))
        XCTAssertEqual(field("city", in: address.schema)?.schema.typeSignature, "string")
        XCTAssertEqual(field("zip", in: address.schema)?.schema.typeSignature, "int")
    }

    func testHeterogeneousArrayElementUnion() async throws {
        let schema = try await inferFromIndex(json: #"[1,"two",3]"#)
        let element = try XCTUnwrap(schema.root.element)
        XCTAssertEqual(element.typeSignature, "int | string")
        XCTAssertEqual(schema.root.typeSignature, "array")
    }

    func testDepthCapTruncates() async throws {
        // 10 levels deep, cap at 3 — must not descend past the cap.
        var json = #"{"v":1}"#
        for _ in 0..<10 { json = #"{"child":\#(json)}"# }
        let schema = try await inferFromIndex(json: json, maxDepth: 3)

        var node = schema.root
        var depth = 0
        while let child = field("child", in: node) {
            node = child.schema
            depth += 1
        }
        XCTAssertLessThanOrEqual(depth, 3)
        XCTAssertTrue(node.isDepthTruncated)
    }

    // MARK: - Subtree inference

    func testSubtreeInference() async throws {
        let json = #"{"meta":{"v":1},"items":[{"id":1},{"id":2}]}"#
        let file = try makeFile(json: json)
        let si = try await JSONParser().buildIndex(from: file)

        // Find the array node (value child of the "items" keyValue entry).
        let itemsKV = try XCTUnwrap(si.entries.first { $0.key == "items" })
        let arrayEntry = try XCTUnwrap(si.entries.first {
            $0.parentID == itemsKV.id && $0.nodeType == .array
        })

        let schema = SchemaInferenceEngine.infer(from: si, file: file,
                                                 rootID: arrayEntry.id)
        XCTAssertEqual(schema.root.typeSignature, "object[]")
        let element = try XCTUnwrap(schema.root.element)
        XCTAssertEqual(element.occurrences, 2)
        XCTAssertNil(field("meta", in: element))   // sibling subtree not included
    }

    // MARK: - NodeIndex path (small files)

    func testNodeIndexPathMatchesStructuralIndexPath() async throws {
        let json = #"[{"id":1,"name":"a","opt":true},{"id":2,"name":"b"},{"id":"x"}]"#
        let a = try await inferFromIndex(json: json)
        let b = try await inferFromNodeIndex(json: json)
        XCTAssertEqual(a.root, b.root)
        XCTAssertEqual(a.inconsistencies, b.inconsistencies)
    }

    func testNodeIndexSubtree() async throws {
        let json = #"{"meta":{"v":1},"items":[{"id":1},{"id":2}]}"#
        let file = try makeFile(json: json)
        let si = try await JSONParser().buildIndex(from: file)
        let idx = si.buildNodeIndex()

        let itemsKV = try XCTUnwrap(si.entries.first { $0.key == "items" })
        let arrayEntry = try XCTUnwrap(si.entries.first {
            $0.parentID == itemsKV.id && $0.nodeType == .array
        })

        let schema = SchemaInferenceEngine.infer(from: idx, file: file,
                                                 rootID: arrayEntry.id)
        XCTAssertEqual(schema.root.typeSignature, "object[]")
        XCTAssertEqual(schema.root.element?.occurrences, 2)
    }

    // MARK: - Text rendering (Copy Schema)

    func testRenderedTextContainsSignaturesAndConflicts() async throws {
        let schema = try await inferFromIndex(
            json: #"{"items":[{"age":1},{"age":2},{"age":"x"}],"name":"a"}"#)
        let text = schema.renderedText
        XCTAssertTrue(text.contains("items: object[]"), "got:\n\(text)")
        XCTAssertTrue(text.contains("age: int | string"), "got:\n\(text)")
        XCTAssertTrue(text.contains("⚠"), "got:\n\(text)")
        XCTAssertTrue(text.contains("name: string"), "got:\n\(text)")
        // Nested lines are indented deeper than their parents.
        let itemsIndent = text.split(separator: "\n")
            .first { $0.contains("items:") }!.prefix { $0 == " " }.count
        let ageIndent = text.split(separator: "\n")
            .first { $0.contains("age:") }!.prefix { $0 == " " }.count
        XCTAssertGreaterThan(ageIndent, itemsIndent)
    }

    // MARK: - Lazy path (simdjson-shaped entries: nil keys, nil values)

    /// Build a real ≥5 MB JSON file so `JSONParser.buildIndex` takes the simdjson
    /// path, where `IndexEntry.key`/`parsedValue` are nil and the engine must
    /// resolve both from mmap'd bytes.
    func testSimdjsonLazyPath() async throws {
        var rows: [String] = []
        rows.reserveCapacity(120_000)
        for i in 0..<120_000 {
            if i % 40_000 == 39_999 {
                // sparse anomaly: string id, missing "active"
                rows.append(#"{"id":"anomaly-\#(i)","name":"user \#(i)"}"#)
            } else {
                rows.append(#"{"id":\#(i),"name":"user \#(i)","active":\#(i % 2 == 0)}"#)
            }
        }
        let json = "[" + rows.joined(separator: ",") + "]"
        XCTAssertGreaterThan(UInt64(json.utf8.count), JSONParser.foundationThreshold,
                             "test must exercise the simdjson path")

        let file = try makeFile(json: json)
        let si = try await JSONParser().buildIndex(from: file)
        // Confirm we're on the lazy path (keys not eagerly parsed).
        XCTAssertNil(si.entries.first(where: { $0.nodeType == .keyValue })?.key)

        let schema = SchemaInferenceEngine.infer(from: si, file: file)
        XCTAssertEqual(schema.root.typeSignature, "object[]")

        let element = try XCTUnwrap(schema.root.element)
        XCTAssertEqual(element.occurrences, 120_000)

        let id = try XCTUnwrap(field("id", in: element))
        XCTAssertTrue(id.schema.hasKindConflict)
        XCTAssertEqual(id.schema.kindCounts[.integer], 119_997)
        XCTAssertEqual(id.schema.kindCounts[.string], 3)

        let active = try XCTUnwrap(field("active", in: element))
        XCTAssertTrue(active.isOptional)
        XCTAssertEqual(active.presence, 119_997)
        XCTAssertEqual(active.schema.typeSignature, "bool")

        let inc = schema.inconsistencies.first { $0.path == "$[].id" }
        XCTAssertNotNil(inc)
        XCTAssertTrue(try XCTUnwrap(inc).message.contains("3 of 120000")
                      || (try XCTUnwrap(inc).message.contains("3 of 120,000")),
                      "message: \(String(describing: inc?.message))")
    }

    /// Escaped keys and floats/exponents must decode correctly from raw bytes.
    func testLazyPathEscapedKeysAndNumberSniffing() async throws {
        // Pad with a filler row so the file crosses the simdjson threshold.
        let filler = String(repeating: "x", count: 64)
        var rows = (0..<90_000).map {
            #"{"a\"b":\#($0),"exp":1e3,"neg":-2.5,"plainA":"v\#(filler)"}"#
        }
        rows.append(#"{"a\"b":true}"#)
        let json = "[" + rows.joined(separator: ",") + "]"
        XCTAssertGreaterThan(UInt64(json.utf8.count), JSONParser.foundationThreshold)

        let file = try makeFile(json: json)
        let si = try await JSONParser().buildIndex(from: file)
        let schema = SchemaInferenceEngine.infer(from: si, file: file)
        let element = try XCTUnwrap(schema.root.element)

        let escaped = try XCTUnwrap(field(#"a"b"#, in: element))
        XCTAssertEqual(escaped.presence, 90_001)
        XCTAssertTrue(escaped.schema.hasKindConflict)   // int + bool

        XCTAssertEqual(field("exp", in: element)?.schema.typeSignature, "number")
        XCTAssertEqual(field("neg", in: element)?.schema.typeSignature, "number")
        XCTAssertEqual(field("plainA", in: element)?.schema.typeSignature, "string")
    }
}
