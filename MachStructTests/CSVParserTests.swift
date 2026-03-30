import XCTest
@testable import MachStructCore

final class CSVParserTests: XCTestCase {

    // MARK: - Helpers

    private func makeFile(csv: String, ext: String = "csv") throws -> MappedFile {
        let data = csv.data(using: .utf8)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return try MappedFile(url: url)
    }

    private func buildIndex(csv: String) async throws -> StructuralIndex {
        let file = try makeFile(csv: csv)
        return try await CSVParser().buildIndex(from: file)
    }

    private func csvMeta(_ entry: IndexEntry, file: StaticString = #file, line: UInt = #line) -> CSVMetadata? {
        guard case .csv(let m) = entry.metadata else {
            XCTFail("Expected .csv metadata", file: file, line: line)
            return nil
        }
        return m
    }

    // MARK: - Supported extensions

    func testSupportedExtensions() {
        XCTAssertTrue(CSVParser.supportedExtensions.contains("csv"))
        XCTAssertTrue(CSVParser.supportedExtensions.contains("tsv"))
    }

    // MARK: - Basic parsing

    func testHeaderedCSV() async throws {
        let csv = "name,age,city\nAlice,30,NYC\nBob,25,LA\n"
        let index = try await buildIndex(csv: csv)

        // root(array) + 2×[object + 3×(keyValue + scalar)] = 1 + 2*(1+3*2) = 15
        XCTAssertEqual(index.entries.count, 15)
        XCTAssertEqual(index.entries[0].nodeType, .array)   // root
        XCTAssertEqual(index.entries[0].childCount, 2)
        XCTAssertEqual(index.entries[1].nodeType, .object)  // row 1
        XCTAssertEqual(index.entries[1].childCount, 3)
        XCTAssertEqual(index.entries[2].nodeType, .keyValue)
        XCTAssertEqual(index.entries[2].key, "name")
        XCTAssertEqual(index.entries[3].nodeType, .scalar)
        XCTAssertEqual(index.entries[3].parsedValue, .string("Alice"))
        XCTAssertEqual(index.entries[4].key, "age")
        XCTAssertEqual(index.entries[5].parsedValue, .integer(30))
        XCTAssertEqual(index.entries[6].key, "city")
        XCTAssertEqual(index.entries[7].parsedValue, .string("NYC"))
    }

    func testHeadererCSVRowDepths() async throws {
        let csv = "a,b\n1,2\n"
        let index = try await buildIndex(csv: csv)
        XCTAssertEqual(index.entries[0].depth, 0)   // root array
        XCTAssertEqual(index.entries[1].depth, 1)   // row object
        XCTAssertEqual(index.entries[2].depth, 2)   // keyValue
        XCTAssertEqual(index.entries[3].depth, 3)   // scalar
    }

    func testNoHeaderCSV() async throws {
        // All-numeric rows → no header detected
        let csv = "1,2,3\n4,5,6\n"
        let index = try await buildIndex(csv: csv)
        // root + 2*(array + 3 scalars) = 1 + 2*4 = 9
        XCTAssertEqual(index.entries.count, 9)
        XCTAssertEqual(index.entries[0].nodeType, .array)   // root
        XCTAssertEqual(index.entries[1].nodeType, .array)   // row 0
        XCTAssertEqual(index.entries[2].nodeType, .scalar)
        XCTAssertEqual(index.entries[2].key, "0")
        XCTAssertEqual(index.entries[2].parsedValue, .integer(1))
    }

    // MARK: - Type inference

    func testIntegerCells() async throws {
        let csv = "n\n42\n-7\n"
        let index = try await buildIndex(csv: csv)
        let scalars = index.entries.filter { $0.nodeType == .scalar }
        XCTAssertEqual(scalars[0].parsedValue, .integer(42))
        XCTAssertEqual(scalars[1].parsedValue, .integer(-7))
    }

    func testFloatCells() async throws {
        let csv = "n\n3.14\n-0.5\n"
        let index = try await buildIndex(csv: csv)
        let scalars = index.entries.filter { $0.nodeType == .scalar }
        XCTAssertEqual(scalars[0].parsedValue, .float(3.14))
        XCTAssertEqual(scalars[1].parsedValue, .float(-0.5))
    }

    func testBooleanCells() async throws {
        let csv = "flag\ntrue\nfalse\n"
        let index = try await buildIndex(csv: csv)
        let scalars = index.entries.filter { $0.nodeType == .scalar }
        XCTAssertEqual(scalars[0].parsedValue, .boolean(true))
        XCTAssertEqual(scalars[1].parsedValue, .boolean(false))
    }

    func testNullCells() async throws {
        let csv = "val\nnull\n"
        let index = try await buildIndex(csv: csv)
        let scalar = index.entries.first { $0.nodeType == .scalar }!
        XCTAssertEqual(scalar.parsedValue, .null)
    }

    func testMixedTypesPerColumn() async throws {
        let csv = "x\nhello\n42\ntrue\n"
        let index = try await buildIndex(csv: csv)
        let scalars = index.entries.filter { $0.nodeType == .scalar }
        XCTAssertEqual(scalars[0].parsedValue, .string("hello"))
        XCTAssertEqual(scalars[1].parsedValue, .integer(42))
        XCTAssertEqual(scalars[2].parsedValue, .boolean(true))
    }

    // MARK: - Quoted fields (RFC 4180)

    func testQuotedFieldWithComma() async throws {
        let csv = "name,address\nAlice,\"123 Main, Suite 4\"\n"
        let index = try await buildIndex(csv: csv)
        let scalars = index.entries.filter { $0.nodeType == .scalar }
        XCTAssertEqual(scalars[1].parsedValue, .string("123 Main, Suite 4"))
    }

    func testQuotedFieldWithEmbeddedQuote() async throws {
        let csv = "quote\n\"say \"\"hello\"\"\"\n"
        let index = try await buildIndex(csv: csv)
        let scalar = index.entries.first { $0.nodeType == .scalar }!
        XCTAssertEqual(scalar.parsedValue, .string("say \"hello\""))
    }

    func testQuotedFieldWithNewline() async throws {
        let csv = "text\n\"line1\nline2\"\n"
        let index = try await buildIndex(csv: csv)
        let scalar = index.entries.first { $0.nodeType == .scalar }!
        if case .string(let s) = scalar.parsedValue {
            XCTAssertTrue(s.contains("line1"))
            XCTAssertTrue(s.contains("line2"))
        } else {
            XCTFail("Expected string scalar")
        }
    }

    func testEmptyQuotedField() async throws {
        let csv = "a,b\n\"\",2\n"
        let index = try await buildIndex(csv: csv)
        let scalars = index.entries.filter { $0.nodeType == .scalar }
        // "" → empty string
        XCTAssertEqual(scalars[0].parsedValue, .string(""))
        XCTAssertEqual(scalars[1].parsedValue, .integer(2))
    }

    // MARK: - Delimiter auto-detection

    func testSemicolonDelimiter() async throws {
        let csv = "a;b;c\n1;2;3\n4;5;6\n"
        let index = try await buildIndex(csv: csv)
        // Should detect ';' → 3 columns
        XCTAssertEqual(index.entries[1].childCount, 3)  // row object has 3 key-values
        let meta = csvMeta(index.entries[0])!
        XCTAssertEqual(meta.delimiter, ";")
    }

    func testTabDelimiter() async throws {
        let csv = "a\tb\tc\n1\t2\t3\n"
        let index = try await buildIndex(csv: csv)
        let meta = csvMeta(index.entries[0])!
        XCTAssertEqual(meta.delimiter, "\t")
    }

    func testPipeDelimiter() async throws {
        let csv = "a|b|c\n1|2|3\n4|5|6\n7|8|9\n"
        let index = try await buildIndex(csv: csv)
        let meta = csvMeta(index.entries[0])!
        XCTAssertEqual(meta.delimiter, "|")
    }

    // MARK: - Header detection

    func testHeaderDetectedWhenAllStrings() async throws {
        let csv = "name,age,city\nAlice,30,NYC\n"
        let index = try await buildIndex(csv: csv)
        let meta = csvMeta(index.entries[0])!
        XCTAssertTrue(meta.hasHeader)
        // Row is object (has column names as keys)
        XCTAssertEqual(index.entries[1].nodeType, .object)
    }

    func testNoHeaderWhenFirstRowNumeric() async throws {
        let csv = "1,2,3\n4,5,6\n"
        let index = try await buildIndex(csv: csv)
        let meta = csvMeta(index.entries[0])!
        XCTAssertFalse(meta.hasHeader)
        // Row is array (positional)
        XCTAssertEqual(index.entries[1].nodeType, .array)
    }

    // MARK: - Column index metadata

    func testColumnIndexOnScalars() async throws {
        let csv = "a,b,c\n1,2,3\n"
        let index = try await buildIndex(csv: csv)
        let scalars = index.entries.filter { $0.nodeType == .scalar }
        XCTAssertEqual(scalars.count, 3)
        XCTAssertEqual(csvMeta(scalars[0])?.columnIndex, 0)
        XCTAssertEqual(csvMeta(scalars[1])?.columnIndex, 1)
        XCTAssertEqual(csvMeta(scalars[2])?.columnIndex, 2)
    }

    // MARK: - Line-ending handling

    func testCRLFLineEndings() async throws {
        let csv = "a,b\r\n1,2\r\n3,4\r\n"
        let index = try await buildIndex(csv: csv)
        XCTAssertEqual(index.entries[0].childCount, 2)
        let scalars = index.entries.filter { $0.nodeType == .scalar }
        XCTAssertEqual(scalars.count, 4)
    }

    func testCROnlyLineEndings() async throws {
        let csv = "a,b\r1,2\r3,4\r"
        let index = try await buildIndex(csv: csv)
        XCTAssertEqual(index.entries[0].childCount, 2)
    }

    // MARK: - Edge cases

    func testSingleRow() async throws {
        // Only a header → 0 data rows
        let csv = "name,age\n"
        let index = try await buildIndex(csv: csv)
        // hasHeader = true but only 1 row → treated as no-header data row
        XCTAssertGreaterThanOrEqual(index.entries.count, 1)
    }

    func testSingleColumn() async throws {
        let csv = "value\nhello\nworld\n"
        let index = try await buildIndex(csv: csv)
        let scalars = index.entries.filter { $0.nodeType == .scalar }
        XCTAssertEqual(scalars.count, 2)
        XCTAssertEqual(scalars[0].parsedValue, .string("hello"))
    }

    func testEmptyCell() async throws {
        let csv = "a,b\n1,\n"
        let index = try await buildIndex(csv: csv)
        let scalars = index.entries.filter { $0.nodeType == .scalar }
        XCTAssertEqual(scalars[1].parsedValue, .string(""))
    }

    // MARK: - NodeIndex integration

    func testBuildNodeIndex() async throws {
        let csv = "name,score\nAlice,95\nBob,87\n"
        let file = try makeFile(csv: csv)
        let structural = try await CSVParser().buildIndex(from: file)
        let nodeIndex = structural.buildNodeIndex()

        let root = nodeIndex.node(for: nodeIndex.rootID)!
        XCTAssertEqual(root.type, .array)

        let rows = nodeIndex.children(of: root.id)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].type, .object)

        let aliceKVs = nodeIndex.children(of: rows[0].id)
        XCTAssertEqual(aliceKVs.count, 2)
        let nameKV = aliceKVs.first { $0.key == "name" }!
        let nameCell = nodeIndex.children(of: nameKV.id).first!
        XCTAssertEqual(nameCell.value, .scalar(.string("Alice")))
    }

    // MARK: - parseValue

    func testParseValueScalar() throws {
        let parser = CSVParser()
        let entry = IndexEntry(id: .generate(), nodeType: .scalar, depth: 3, parentID: nil,
                               parsedValue: .integer(42))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("d.csv")
        try "a\n42".data(using: .utf8)!.write(to: tmp)
        let file = try MappedFile(url: tmp)
        XCTAssertEqual(try parser.parseValue(entry: entry, from: file), .scalar(.integer(42)))
    }

    func testParseValueContainer() throws {
        let parser = CSVParser()
        let entry = IndexEntry(id: .generate(), nodeType: .array, depth: 0, parentID: nil,
                               childCount: 3)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("d2.csv")
        try "a,b,c".data(using: .utf8)!.write(to: tmp)
        let file = try MappedFile(url: tmp)
        XCTAssertEqual(try parser.parseValue(entry: entry, from: file), .container(childCount: 3))
    }

    // MARK: - Serialize

    func testSerializePlainString() throws {
        let parser = CSVParser()
        let data = try parser.serialize(value: .scalar(.string("hello")))
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello")
    }

    func testSerializeStringWithComma() throws {
        let parser = CSVParser()
        let data = try parser.serialize(value: .scalar(.string("a,b")))
        let result = String(data: data, encoding: .utf8)!
        XCTAssertEqual(result, "\"a,b\"")
    }

    func testSerializeStringWithQuote() throws {
        let parser = CSVParser()
        let data = try parser.serialize(value: .scalar(.string("say \"hi\"")))
        let result = String(data: data, encoding: .utf8)!
        XCTAssertEqual(result, "\"say \"\"hi\"\"\"")
    }

    func testSerializeInteger() throws {
        let parser = CSVParser()
        let data = try parser.serialize(value: .scalar(.integer(42)))
        XCTAssertEqual(String(data: data, encoding: .utf8), "42")
    }

    func testSerializeFloat() throws {
        let parser = CSVParser()
        let data = try parser.serialize(value: .scalar(.float(3.14)))
        XCTAssertEqual(String(data: data, encoding: .utf8), "3.14")
    }

    func testSerializeBoolean() throws {
        let parser = CSVParser()
        let data = try parser.serialize(value: .scalar(.boolean(false)))
        XCTAssertEqual(String(data: data, encoding: .utf8), "false")
    }

    func testSerializeNull() throws {
        let parser = CSVParser()
        let data = try parser.serialize(value: .scalar(.null))
        XCTAssertEqual(String(data: data, encoding: .utf8), "")
    }

    func testSerializeContainerThrows() {
        let parser = CSVParser()
        XCTAssertThrowsError(try parser.serialize(value: .container(childCount: 1)))
    }

    // MARK: - Validate

    func testValidCSV() async throws {
        let file = try makeFile(csv: "a,b,c\n1,2,3\n4,5,6\n")
        let issues = try await CSVParser().validate(file: file)
        XCTAssertTrue(issues.isEmpty)
    }

    func testJaggedRowReportsWarning() async throws {
        let file = try makeFile(csv: "a,b,c\n1,2\n4,5,6\n")
        let issues = try await CSVParser().validate(file: file)
        XCTAssertFalse(issues.isEmpty)
        XCTAssertEqual(issues[0].severity, .warning)
        XCTAssertTrue(issues[0].message.contains("2"))   // "2 columns"
    }

    // MARK: - Progressive streaming

    func testProgressiveStreamingCompletesAndBatches() async throws {
        let rows = (1...200).map { "col\($0 % 3),\($0)" }.joined(separator: "\n")
        let file = try makeFile(csv: "header1,header2\n" + rows)

        var batchCount = 0
        var didComplete = false

        for await progress in CSVParser().parseProgressively(file: file) {
            switch progress {
            case .nodesIndexed: batchCount += 1
            case .complete:     didComplete = true
            case .error(let e): XCTFail("Error: \(e)")
            case .warning:      break
            }
        }
        XCTAssertTrue(didComplete)
        XCTAssertGreaterThan(batchCount, 0)
    }

    // MARK: - TSV support

    func testTSVFile() async throws {
        let tsv = "name\tscore\nAlice\t95\nBob\t87\n"
        let file = try makeFile(csv: tsv, ext: "tsv")
        let index = try await CSVParser().buildIndex(from: file)
        let meta = csvMeta(index.entries[0])!
        XCTAssertEqual(meta.delimiter, "\t")
        let scalars = index.entries.filter { $0.nodeType == .scalar }
        XCTAssertEqual(scalars.count, 4)
    }
}
