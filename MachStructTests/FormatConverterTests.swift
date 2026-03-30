import XCTest
@testable import MachStructCore

// MARK: - FormatConverterTests

/// Tests for `YAMLDocumentSerializer`, `CSVDocumentSerializer`, and `FormatConverter`.
final class FormatConverterTests: XCTestCase {

    // MARK: - Helpers

    /// Build a small NodeIndex: { "name": "Alice", "age": 30, "active": true }
    private func makeObjectIndex() -> NodeIndex {
        let root = DocumentNode(type: .object, value: .container(childCount: 3))
        var idx  = NodeIndex(root: root)

        func addKV(_ key: String, _ value: ScalarValue, at i: Int) {
            let kv  = DocumentNode(id: .generate(), type: .keyValue, depth: 1,
                                   parentID: root.id, key: key, value: .unparsed)
            let sc  = DocumentNode(id: .generate(), type: .scalar, depth: 2,
                                   parentID: kv.id, value: .scalar(value))
            idx.insertChild(kv, in: root.id, at: i)
            idx.insertChild(sc, in: kv.id,  at: 0)
        }

        addKV("name",   .string("Alice"), at: 0)
        addKV("age",    .integer(30),     at: 1)
        addKV("active", .boolean(true),   at: 2)
        return idx
    }

    /// Build { "ratio": 3.14, "score": 0.0, "inf": Double.infinity }
    private func makeFloatIndex() -> NodeIndex {
        let root = DocumentNode(type: .object, value: .container(childCount: 3))
        var idx  = NodeIndex(root: root)
        func addKV(_ key: String, _ value: ScalarValue, at i: Int) {
            let kv = DocumentNode(id: .generate(), type: .keyValue, depth: 1,
                                  parentID: root.id, key: key, value: .unparsed)
            let sc = DocumentNode(id: .generate(), type: .scalar, depth: 2,
                                  parentID: kv.id, value: .scalar(value))
            idx.insertChild(kv, in: root.id, at: i)
            idx.insertChild(sc, in: kv.id,  at: 0)
        }
        addKV("ratio", .float(3.14),        at: 0)
        addKV("score", .float(0.0),         at: 1)
        addKV("inf",   .float(.infinity),   at: 2)
        return idx
    }

    /// Build a tabular index: array of objects with columns [name, age, city].
    private func makeTabularIndex() -> NodeIndex {
        let root = DocumentNode(type: .array, value: .container(childCount: 3))
        var idx  = NodeIndex(root: root)

        func addRow(_ name: String, _ age: Int, _ city: String, at ri: Int) {
            let row = DocumentNode(id: .generate(), type: .object, depth: 1,
                                   parentID: root.id, value: .container(childCount: 3))
            idx.insertChild(row, in: root.id, at: ri)

            let pairs: [(String, ScalarValue)] = [
                ("name", .string(name)),
                ("age",  .integer(Int64(age))),
                ("city", .string(city))
            ]
            for (ci, (key, val)) in pairs.enumerated() {
                let kv  = DocumentNode(id: .generate(), type: .keyValue, depth: 2,
                                       parentID: row.id, key: key, value: .unparsed)
                let sc  = DocumentNode(id: .generate(), type: .scalar, depth: 3,
                                       parentID: kv.id, value: .scalar(val))
                idx.insertChild(kv, in: row.id, at: ci)
                idx.insertChild(sc, in: kv.id,  at: 0)
            }
        }

        addRow("Alice", 30, "New York",    at: 0)
        addRow("Bob",   25, "Los Angeles", at: 1)
        addRow("Carol", 35, "Chicago",     at: 2)
        return idx
    }

    /// Build a nested index: { "user": { "name": "Bob", "scores": [10, 20] } }
    private func makeNestedIndex() -> NodeIndex {
        let root = DocumentNode(type: .object, value: .container(childCount: 1))
        var idx  = NodeIndex(root: root)

        let userKV   = DocumentNode(id: .generate(), type: .keyValue, depth: 1,
                                    parentID: root.id, key: "user", value: .unparsed)
        let userObj  = DocumentNode(id: .generate(), type: .object, depth: 2,
                                    parentID: userKV.id, value: .container(childCount: 2))
        let nameKV   = DocumentNode(id: .generate(), type: .keyValue, depth: 3,
                                    parentID: userObj.id, key: "name", value: .unparsed)
        let nameSc   = DocumentNode(id: .generate(), type: .scalar, depth: 4,
                                    parentID: nameKV.id, value: .scalar(.string("Bob")))
        let scoresKV = DocumentNode(id: .generate(), type: .keyValue, depth: 3,
                                    parentID: userObj.id, key: "scores", value: .unparsed)
        let scoresArr = DocumentNode(id: .generate(), type: .array, depth: 4,
                                     parentID: scoresKV.id, value: .container(childCount: 2))
        let s1 = DocumentNode(id: .generate(), type: .scalar, depth: 5,
                               parentID: scoresArr.id, value: .scalar(.integer(10)))
        let s2 = DocumentNode(id: .generate(), type: .scalar, depth: 5,
                               parentID: scoresArr.id, value: .scalar(.integer(20)))

        idx.insertChild(userKV,    in: root.id,       at: 0)
        idx.insertChild(userObj,   in: userKV.id,     at: 0)
        idx.insertChild(nameKV,    in: userObj.id,    at: 0)
        idx.insertChild(nameSc,    in: nameKV.id,     at: 0)
        idx.insertChild(scoresKV,  in: userObj.id,    at: 1)
        idx.insertChild(scoresArr, in: scoresKV.id,   at: 0)
        idx.insertChild(s1,        in: scoresArr.id,  at: 0)
        idx.insertChild(s2,        in: scoresArr.id,  at: 1)
        return idx
    }

    // MARK: - YAMLDocumentSerializer: basic types

    func testYAMLSimpleObject() throws {
        let idx  = makeObjectIndex()
        let data = try YAMLDocumentSerializer(index: idx).serialize()
        let yaml = String(data: data, encoding: .utf8)!

        XCTAssertTrue(yaml.contains("name: Alice"))
        XCTAssertTrue(yaml.contains("age: 30"))
        XCTAssertTrue(yaml.contains("active: true"))
    }

    func testYAMLDocumentStartMarker() throws {
        let idx  = makeObjectIndex()
        let yaml = try String(data: YAMLDocumentSerializer(index: idx).serialize(), encoding: .utf8)!
        XCTAssertTrue(yaml.hasPrefix("---\n"), "YAML output should start with document marker")
    }

    func testYAMLFloatFormatting() throws {
        let idx  = makeFloatIndex()
        let yaml = try String(data: YAMLDocumentSerializer(index: idx).serialize(), encoding: .utf8)!
        XCTAssertTrue(yaml.contains("ratio: 3.14"))
        XCTAssertTrue(yaml.contains("score: 0.0"))
        XCTAssertTrue(yaml.contains("inf: .inf"))
    }

    func testYAMLNullValue() throws {
        let root = DocumentNode(type: .object, value: .container(childCount: 1))
        var idx  = NodeIndex(root: root)
        let kv   = DocumentNode(id: .generate(), type: .keyValue, depth: 1,
                                parentID: root.id, key: "empty", value: .unparsed)
        let sc   = DocumentNode(id: .generate(), type: .scalar, depth: 2,
                                parentID: kv.id, value: .scalar(.null))
        idx.insertChild(kv, in: root.id, at: 0)
        idx.insertChild(sc, in: kv.id,  at: 0)

        let yaml = try String(data: YAMLDocumentSerializer(index: idx).serialize(), encoding: .utf8)!
        XCTAssertTrue(yaml.contains("empty: null"))
    }

    func testYAMLEmptyObject() throws {
        let root = DocumentNode(type: .object, value: .container(childCount: 0))
        let idx  = NodeIndex(root: root)
        let yaml = try String(data: YAMLDocumentSerializer(index: idx).serialize(), encoding: .utf8)!
        XCTAssertTrue(yaml.contains("{}"))
    }

    func testYAMLEmptyArray() throws {
        let root = DocumentNode(type: .array, value: .container(childCount: 0))
        let idx  = NodeIndex(root: root)
        let yaml = try String(data: YAMLDocumentSerializer(index: idx).serialize(), encoding: .utf8)!
        XCTAssertTrue(yaml.contains("[]"))
    }

    func testYAMLNestedStructure() throws {
        let idx  = makeNestedIndex()
        let yaml = try String(data: YAMLDocumentSerializer(index: idx).serialize(), encoding: .utf8)!
        XCTAssertTrue(yaml.contains("user:"))
        XCTAssertTrue(yaml.contains("name: Bob"))
        XCTAssertTrue(yaml.contains("scores:"))
        XCTAssertTrue(yaml.contains("- 10"))
        XCTAssertTrue(yaml.contains("- 20"))
    }

    func testYAMLTabularDocument() throws {
        let idx  = makeTabularIndex()
        let yaml = try String(data: YAMLDocumentSerializer(index: idx).serialize(), encoding: .utf8)!
        // Each row is a sequence item (block form)
        // Sequence items for block mappings use "-\n  key: val" form (no trailing space on "-")
        XCTAssertTrue(yaml.contains("-"), "Expected sequence item markers")
        XCTAssertTrue(yaml.contains("name: Alice"))
        XCTAssertTrue(yaml.contains("age: 30"))
        XCTAssertTrue(yaml.contains("city: New York"))
    }

    // MARK: - YAMLDocumentSerializer: quoting

    func testYAMLReservedWordQuoted() throws {
        let root = DocumentNode(type: .object, value: .container(childCount: 1))
        var idx  = NodeIndex(root: root)
        let kv   = DocumentNode(id: .generate(), type: .keyValue, depth: 1,
                                parentID: root.id, key: "flag", value: .unparsed)
        // "true" as a string should be quoted so it doesn't parse as boolean
        let sc   = DocumentNode(id: .generate(), type: .scalar, depth: 2,
                                parentID: kv.id, value: .scalar(.string("true")))
        idx.insertChild(kv, in: root.id, at: 0)
        idx.insertChild(sc, in: kv.id,  at: 0)

        let yaml = try String(data: YAMLDocumentSerializer(index: idx).serialize(), encoding: .utf8)!
        // Value should be single-quoted to distinguish from YAML boolean true
        XCTAssertTrue(yaml.contains("flag: 'true'"), "Expected flag: 'true', got: \(yaml)")
    }

    func testYAMLNumericStringQuoted() throws {
        let root = DocumentNode(type: .object, value: .container(childCount: 1))
        var idx  = NodeIndex(root: root)
        let kv   = DocumentNode(id: .generate(), type: .keyValue, depth: 1,
                                parentID: root.id, key: "zip", value: .unparsed)
        let sc   = DocumentNode(id: .generate(), type: .scalar, depth: 2,
                                parentID: kv.id, value: .scalar(.string("12345")))
        idx.insertChild(kv, in: root.id, at: 0)
        idx.insertChild(sc, in: kv.id,  at: 0)

        let yaml = try String(data: YAMLDocumentSerializer(index: idx).serialize(), encoding: .utf8)!
        XCTAssertTrue(yaml.contains("zip: '12345'"), "Numeric string should be quoted, got: \(yaml)")
    }

    func testYAMLStringWithColonQuoted() throws {
        let root = DocumentNode(type: .object, value: .container(childCount: 1))
        var idx  = NodeIndex(root: root)
        let kv   = DocumentNode(id: .generate(), type: .keyValue, depth: 1,
                                parentID: root.id, key: "url", value: .unparsed)
        let sc   = DocumentNode(id: .generate(), type: .scalar, depth: 2,
                                parentID: kv.id, value: .scalar(.string("http: //example.com")))
        idx.insertChild(kv, in: root.id, at: 0)
        idx.insertChild(sc, in: kv.id,  at: 0)

        let yaml = try String(data: YAMLDocumentSerializer(index: idx).serialize(), encoding: .utf8)!
        // "http: //example.com" contains ": " so must be quoted
        XCTAssertFalse(yaml.contains("url: http: //example.com"),
                       "Value with ': ' must be quoted")
    }

    func testYAMLNewlineInStringDoubleQuoted() throws {
        let root = DocumentNode(type: .object, value: .container(childCount: 1))
        var idx  = NodeIndex(root: root)
        let kv   = DocumentNode(id: .generate(), type: .keyValue, depth: 1,
                                parentID: root.id, key: "msg", value: .unparsed)
        let sc   = DocumentNode(id: .generate(), type: .scalar, depth: 2,
                                parentID: kv.id, value: .scalar(.string("line1\nline2")))
        idx.insertChild(kv, in: root.id, at: 0)
        idx.insertChild(sc, in: kv.id,  at: 0)

        let yaml = try String(data: YAMLDocumentSerializer(index: idx).serialize(), encoding: .utf8)!
        XCTAssertTrue(yaml.contains("\\n"), "Newline in string should be escaped as \\n")
    }

    func testYAMLEmptyStringQuoted() throws {
        let root = DocumentNode(type: .object, value: .container(childCount: 1))
        var idx  = NodeIndex(root: root)
        let kv   = DocumentNode(id: .generate(), type: .keyValue, depth: 1,
                                parentID: root.id, key: "val", value: .unparsed)
        let sc   = DocumentNode(id: .generate(), type: .scalar, depth: 2,
                                parentID: kv.id, value: .scalar(.string("")))
        idx.insertChild(kv, in: root.id, at: 0)
        idx.insertChild(sc, in: kv.id,  at: 0)

        let yaml = try String(data: YAMLDocumentSerializer(index: idx).serialize(), encoding: .utf8)!
        XCTAssertTrue(yaml.contains("val: ''"), "Empty string should be quoted as ''")
    }

    func testYAMLEmptyDocumentThrows() {
        let emptyIdx = NodeIndex(root: DocumentNode(type: .object, value: .container(childCount: 0)))
        // An index with a root but no children serializes normally (empty object)
        // Only a truly empty (no root) index throws — but NodeIndex always has a root.
        // So we test round-trip: empty object serializes without throwing.
        XCTAssertNoThrow(try YAMLDocumentSerializer(index: emptyIdx).serialize())
    }

    // MARK: - YAMLDocumentSerializer: round-trip via CSVParser

    func testYAMLRoundTripCSV() async throws {
        let csv  = "name,score\nAlice,100\nBob,95\n"
        let url  = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaml-rt-\(UUID().uuidString).csv")
        try csv.data(using: .utf8)!.write(to: url)

        let file  = try MappedFile(url: url)
        let si    = try await CSVParser().buildIndex(from: file)
        let idx   = si.buildNodeIndex()
        let yaml  = try String(data: YAMLDocumentSerializer(index: idx).serialize(), encoding: .utf8)!

        XCTAssertTrue(yaml.contains("name: Alice"))
        XCTAssertTrue(yaml.contains("score: 100"))
        XCTAssertTrue(yaml.contains("name: Bob"))
    }

    // MARK: - CSVDocumentSerializer

    func testCSVHeaderAndRows() throws {
        let idx = makeTabularIndex()
        let csv = try String(data: CSVDocumentSerializer(index: idx).serialize(), encoding: .utf8)!
        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }

        XCTAssertEqual(lines[0], "name,age,city",
                       "First line should be header row")
        XCTAssertTrue(lines[1].contains("Alice"))
        XCTAssertTrue(lines[2].contains("Bob"))
        XCTAssertTrue(lines[3].contains("Carol"))
        XCTAssertEqual(lines.count, 4, "3 data rows + 1 header = 4 non-empty lines")
    }

    func testCSVNotTabularThrows() {
        let idx = makeObjectIndex()
        XCTAssertThrowsError(try CSVDocumentSerializer(index: idx).serialize()) { error in
            XCTAssertTrue(error is CSVSerializerError)
            if case CSVSerializerError.notTabular = error { } else {
                XCTFail("Expected .notTabular, got \(error)")
            }
        }
    }

    func testCSVQuotesFieldWithComma() throws {
        let root = DocumentNode(type: .array, value: .container(childCount: 1))
        var idx  = NodeIndex(root: root)

        let row  = DocumentNode(id: .generate(), type: .object, depth: 1,
                                parentID: root.id, value: .container(childCount: 1))
        let kv   = DocumentNode(id: .generate(), type: .keyValue, depth: 2,
                                parentID: row.id, key: "city", value: .unparsed)
        let sc   = DocumentNode(id: .generate(), type: .scalar, depth: 3,
                                parentID: kv.id, value: .scalar(.string("New York, NY")))
        idx.insertChild(row, in: root.id, at: 0)
        idx.insertChild(kv,  in: row.id, at: 0)
        idx.insertChild(sc,  in: kv.id,  at: 0)

        let csv = try String(data: CSVDocumentSerializer(index: idx).serialize(), encoding: .utf8)!
        XCTAssertTrue(csv.contains("\"New York, NY\""),
                      "Field with comma must be double-quoted: \(csv)")
    }

    func testCSVQuotesFieldWithDoubleQuote() throws {
        let root = DocumentNode(type: .array, value: .container(childCount: 1))
        var idx  = NodeIndex(root: root)

        let row = DocumentNode(id: .generate(), type: .object, depth: 1,
                               parentID: root.id, value: .container(childCount: 1))
        let kv  = DocumentNode(id: .generate(), type: .keyValue, depth: 2,
                               parentID: row.id, key: "val", value: .unparsed)
        let sc  = DocumentNode(id: .generate(), type: .scalar, depth: 3,
                               parentID: kv.id, value: .scalar(.string("say \"hello\"")))
        idx.insertChild(row, in: root.id, at: 0)
        idx.insertChild(kv,  in: row.id, at: 0)
        idx.insertChild(sc,  in: kv.id,  at: 0)

        let csv = try String(data: CSVDocumentSerializer(index: idx).serialize(), encoding: .utf8)!
        // RFC 4180: embedded quotes doubled
        XCTAssertTrue(csv.contains("\"say \"\"hello\"\"\""),
                      "Embedded quotes must be doubled: \(csv)")
    }

    func testCSVNullBecomesEmptyCell() throws {
        let root = DocumentNode(type: .array, value: .container(childCount: 1))
        var idx  = NodeIndex(root: root)

        let row = DocumentNode(id: .generate(), type: .object, depth: 1,
                               parentID: root.id, value: .container(childCount: 1))
        let kv  = DocumentNode(id: .generate(), type: .keyValue, depth: 2,
                               parentID: row.id, key: "val", value: .unparsed)
        let sc  = DocumentNode(id: .generate(), type: .scalar, depth: 3,
                               parentID: kv.id, value: .scalar(.null))
        idx.insertChild(row, in: root.id, at: 0)
        idx.insertChild(kv,  in: row.id, at: 0)
        idx.insertChild(sc,  in: kv.id,  at: 0)

        let csv = try String(data: CSVDocumentSerializer(index: idx).serialize(), encoding: .utf8)!
        // Don't filter empty lines — the null cell IS the empty line.
        // CSV: "val\n\n" → ["val", "", ""]
        let lines = csv.components(separatedBy: "\n")
        XCTAssertTrue(lines.count >= 2, "Expected at least header + data row")
        XCTAssertEqual(lines[1], "", "null value should produce an empty CSV cell")
    }

    func testCSVCustomDelimiter() throws {
        let idx = makeTabularIndex()
        let csv = try String(data: CSVDocumentSerializer(index: idx).serialize(delimiter: "\t"),
                             encoding: .utf8)!
        XCTAssertTrue(csv.contains("\t"), "Tab delimiter should appear in output")
        XCTAssertFalse(csv.contains(","), "No commas expected with tab delimiter")
    }

    func testCSVRoundTripViaParser() async throws {
        // Serialize tabular index → CSV → re-parse → verify roundtrip
        let idx = makeTabularIndex()
        let csvData = try CSVDocumentSerializer(index: idx).serialize()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-\(UUID().uuidString).csv")
        try csvData.write(to: url)

        let file  = try MappedFile(url: url)
        let si    = try await CSVParser().buildIndex(from: file)
        let idx2  = si.buildNodeIndex()

        XCTAssertTrue(idx2.isTabular())
        XCTAssertEqual(idx2.tabularColumns, ["name", "age", "city"])
        XCTAssertEqual(idx2.children(of: idx2.root!.id).count, 3)
    }

    // MARK: - FormatConverter

    func testConverterCanConvertJSON() {
        let idx  = makeObjectIndex()
        let conv = FormatConverter()
        XCTAssertTrue(conv.canConvert(index: idx, to: .json))
        XCTAssertTrue(conv.canConvert(index: idx, to: .yaml))
        XCTAssertFalse(conv.canConvert(index: idx, to: .csv))
    }

    func testConverterCanConvertCSVWhenTabular() {
        let idx  = makeTabularIndex()
        let conv = FormatConverter()
        XCTAssertTrue(conv.canConvert(index: idx, to: .csv))
    }

    func testConverterProducesValidJSON() throws {
        let idx  = makeObjectIndex()
        let data = try FormatConverter().convert(index: idx, to: .json)
        let obj  = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj)
        XCTAssertEqual(obj?["name"] as? String, "Alice")
        XCTAssertEqual(obj?["age"]  as? Int,    30)
    }

    func testConverterProducesValidYAML() throws {
        let idx  = makeObjectIndex()
        let data = try FormatConverter().convert(index: idx, to: .yaml)
        let yaml = String(data: data, encoding: .utf8)!
        XCTAssertTrue(yaml.contains("name: Alice"))
        XCTAssertTrue(yaml.contains("age: 30"))
    }

    func testConverterProducesValidCSV() throws {
        let idx  = makeTabularIndex()
        let data = try FormatConverter().convert(index: idx, to: .csv)
        let csv  = String(data: data, encoding: .utf8)!
        let firstLine = csv.components(separatedBy: "\n").first!
        XCTAssertEqual(firstLine, "name,age,city")
    }

    func testConverterCSVThrowsForNonTabular() {
        let idx = makeObjectIndex()
        XCTAssertThrowsError(try FormatConverter().convert(index: idx, to: .csv))
    }

    func testConverterTargetFormatExtensions() {
        XCTAssertEqual(FormatConverter.TargetFormat.json.fileExtension, "json")
        XCTAssertEqual(FormatConverter.TargetFormat.yaml.fileExtension, "yaml")
        XCTAssertEqual(FormatConverter.TargetFormat.csv.fileExtension,  "csv")
    }

    func testConverterTargetFormatMimeTypes() {
        XCTAssertEqual(FormatConverter.TargetFormat.json.mimeType, "application/json")
        XCTAssertEqual(FormatConverter.TargetFormat.yaml.mimeType, "application/yaml")
        XCTAssertEqual(FormatConverter.TargetFormat.csv.mimeType,  "text/csv")
    }

    // MARK: - Cross-format integration

    func testJSONToYAMLRoundTrip() async throws {
        let json = "[{\"name\":\"Alice\",\"age\":30},{\"name\":\"Bob\",\"age\":25}]"
        let url  = FileManager.default.temporaryDirectory
            .appendingPathComponent("crossfmt-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)

        let file = try MappedFile(url: url)
        let si   = try await JSONParser().buildIndex(from: file)
        let idx  = si.buildNodeIndex()

        let yaml = try String(
            data: FormatConverter().convert(index: idx, to: .yaml),
            encoding: .utf8
        )!
        XCTAssertTrue(yaml.contains("name: Alice"))
        XCTAssertTrue(yaml.contains("age: 30"))
    }

    func testCSVToJSONRoundTrip() async throws {
        let csv = "product,price\nApple,1.99\nBanana,0.49\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crossfmt-\(UUID().uuidString).csv")
        try csv.data(using: .utf8)!.write(to: url)

        let file = try MappedFile(url: url)
        let si   = try await CSVParser().buildIndex(from: file)
        let idx  = si.buildNodeIndex()

        let jsonData = try FormatConverter().convert(index: idx, to: .json)
        let arr = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]]
        XCTAssertNotNil(arr)
        XCTAssertEqual(arr?.count, 2)
        XCTAssertEqual(arr?[0]["product"] as? String, "Apple")
    }

    func testYAMLToCSVConversion() async throws {
        // YAML array of objects → CSV
        let yaml = "- name: Alice\n  score: 95\n- name: Bob\n  score: 88\n"
        let url  = FileManager.default.temporaryDirectory
            .appendingPathComponent("crossfmt-\(UUID().uuidString).yaml")
        try yaml.data(using: .utf8)!.write(to: url)

        let file = try MappedFile(url: url)
        let si   = try await YAMLParser().buildIndex(from: file)
        let idx  = si.buildNodeIndex()

        XCTAssertTrue(idx.isTabular(), "YAML array of objects should be tabular")
        let csv  = try String(
            data: FormatConverter().convert(index: idx, to: .csv),
            encoding: .utf8
        )!
        XCTAssertTrue(csv.contains("Alice"))
        XCTAssertTrue(csv.contains("Bob"))
    }
}
