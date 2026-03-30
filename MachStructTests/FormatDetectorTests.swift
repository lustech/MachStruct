import XCTest
@testable import MachStructCore

// MARK: - FormatDetectorTests

/// Tests for `FormatDetector.detect(headerBytes:fileExtension:)`.
///
/// The byte-based overload is used throughout so tests don't need real files
/// on disk.  Integration tests use `detect(file:)` via actual `MappedFile`s.
final class FormatDetectorTests: XCTestCase {

    // MARK: - Helper

    private func detect(_ text: String, ext: String? = nil) -> FormatDetector.DetectedFormat {
        let data = text.data(using: .utf8)!
        return FormatDetector.detect(headerBytes: data, fileExtension: ext)
    }

    // MARK: - JSON detection

    func testJSONObject() {
        XCTAssertEqual(detect("{\"key\": 1}"), .json)
    }

    func testJSONArray() {
        XCTAssertEqual(detect("[1, 2, 3]"), .json)
    }

    func testJSONWithLeadingWhitespace() {
        XCTAssertEqual(detect("   \n  {\"a\": 1}"), .json)
    }

    func testJSONWithLeadingTab() {
        XCTAssertEqual(detect("\t[{\"x\": 1}]"), .json)
    }

    func testJSONArrayOfObjects() {
        XCTAssertEqual(detect("[{\"name\":\"Alice\"},{\"name\":\"Bob\"}]"), .json)
    }

    // MARK: - XML detection

    func testXMLDeclaration() {
        XCTAssertEqual(detect("<?xml version=\"1.0\"?><root/>"), .xml)
    }

    func testXMLElement() {
        XCTAssertEqual(detect("<root><child>val</child></root>"), .xml)
    }

    func testXMLWithLeadingWhitespace() {
        XCTAssertEqual(detect("  \n<catalog><item/></catalog>"), .xml)
    }

    func testHTMLIsDetectedAsXML() {
        // MachStruct doesn't distinguish XML vs HTML at this layer
        XCTAssertEqual(detect("<!DOCTYPE html><html></html>"), .xml)
    }

    // MARK: - YAML detection: explicit markers

    func testYAMLDocumentMarker() {
        XCTAssertEqual(detect("---\nkey: value"), .yaml)
    }

    func testYAMLDirective() {
        XCTAssertEqual(detect("%YAML 1.2\n---\nkey: value"), .yaml)
    }

    func testYAMLTagDirective() {
        XCTAssertEqual(detect("%TAG ! tag:example.com,2000:\n---"), .yaml)
    }

    func testYAMLMarkerWithCR() {
        XCTAssertEqual(detect("---\r\nkey: value"), .yaml)
    }

    // MARK: - YAML detection: structural heuristics

    func testYAMLKeyValueHeuristic() {
        XCTAssertEqual(detect("name: Alice\nage: 30\ncity: NYC"), .yaml)
    }

    func testYAMLSequenceHeuristic() {
        XCTAssertEqual(detect("- item1\n- item2\n- item3"), .yaml)
    }

    func testYAMLBareKeyHeuristic() {
        XCTAssertEqual(detect("config:\n  host: localhost"), .yaml)
    }

    func testYAMLNotConfusedByNumericStart() {
        // Starts with a digit → not YAML heuristic, falls through to extension or default
        let result = detect("42\n43\n44", ext: nil)
        // Should not detect as YAML
        XCTAssertNotEqual(result, .yaml)
    }

    func testYAMLNotConfusedByQuotedStart() {
        // Starts with quote → not a YAML mapping, likely JSON or plain text
        let result = detect("\"hello\"\n\"world\"", ext: nil)
        XCTAssertNotEqual(result, .yaml)
    }

    // MARK: - CSV detection

    func testCSVWithCommaDelimiter() {
        XCTAssertEqual(detect("name,age,city\nAlice,30,NYC\nBob,25,LA"), .csv)
    }

    func testCSVWithTabDelimiter() {
        XCTAssertEqual(detect("name\tage\tcity\nAlice\t30\tNYC\nBob\t25\tLA"), .csv)
    }

    func testCSVWithSemicolonDelimiter() {
        XCTAssertEqual(detect("name;age;city\nAlice;30;NYC\nBob;25;LA"), .csv)
    }

    func testCSVWithPipeDelimiter() {
        XCTAssertEqual(detect("name|age|city\nAlice|30|NYC\nBob|25|LA"), .csv)
    }

    func testCSVWithQuotedFields() {
        let csv = "\"name\",\"age\"\n\"Alice, Jr.\",30\n\"Bob\",25"
        XCTAssertEqual(detect(csv), .csv)
    }

    func testSingleColumnNotCSV() {
        // 1 field per line = no delimiters = not detected as CSV
        let result = detect("name\nAlice\nBob\nCarol", ext: nil)
        XCTAssertNotEqual(result, .csv)
    }

    func testCSVBeatsYAMLForHighFieldCount() {
        // 5 comma-separated columns across 4 lines should win over YAML heuristic
        let csv = "a,b,c,d,e\n1,2,3,4,5\n6,7,8,9,10\n11,12,13,14,15"
        XCTAssertEqual(detect(csv), .csv)
    }

    // MARK: - Extension fallback

    func testExtensionFallbackJSON() {
        // Plain text that doesn't trigger content heuristics → use extension
        XCTAssertEqual(detect("hello world", ext: "json"), .json)
    }

    func testExtensionFallbackYAML() {
        XCTAssertEqual(detect("hello world", ext: "yaml"), .yaml)
    }

    func testExtensionFallbackYML() {
        XCTAssertEqual(detect("hello world", ext: "yml"), .yaml)
    }

    func testExtensionFallbackCSV() {
        XCTAssertEqual(detect("hello world", ext: "csv"), .csv)
    }

    func testExtensionFallbackXML() {
        XCTAssertEqual(detect("hello world", ext: "xml"), .xml)
    }

    func testUnknownExtensionDefaultsToJSON() {
        // No recognisable content + no known extension → .json (safe default)
        XCTAssertEqual(detect("hello world", ext: "foo"), .json)
    }

    func testNoExtensionNoContentDefaultsToJSON() {
        XCTAssertEqual(detect("hello world", ext: nil), .json)
    }

    // MARK: - Content beats extension

    func testJSONContentBeatsCSVExtension() {
        // File named .csv but contains JSON → content wins
        XCTAssertEqual(detect("{\"key\": 1}", ext: "csv"), .json)
    }

    func testXMLContentBeatsJSONExtension() {
        XCTAssertEqual(detect("<root/>", ext: "json"), .xml)
    }

    func testJSONContentBeatsYAMLExtension() {
        XCTAssertEqual(detect("[1, 2, 3]", ext: "yaml"), .json)
    }

    // MARK: - UTF-8 BOM

    func testUTF8BOMStripped() {
        // UTF-8 BOM + JSON
        var data = Data([0xEF, 0xBB, 0xBF])
        data += "{\"a\":1}".data(using: .utf8)!
        XCTAssertEqual(FormatDetector.detect(headerBytes: data), .json)
    }

    func testUTF16BOMFallsBackToExtension() {
        let data = Data([0xFF, 0xFE, 0x00, 0x00])  // UTF-32 LE BOM
        XCTAssertEqual(FormatDetector.detect(headerBytes: data, fileExtension: "json"), .json)
    }

    // MARK: - Edge cases

    func testEmptyDataFallsBackToExtension() {
        XCTAssertEqual(FormatDetector.detect(headerBytes: Data(), fileExtension: "yaml"), .yaml)
    }

    func testAllWhitespace() {
        XCTAssertEqual(detect("   \n\t  \r\n  ", ext: "json"), .json)
    }

    func testSingleBrace() {
        XCTAssertEqual(detect("{"), .json)
    }

    func testSingleAngle() {
        XCTAssertEqual(detect("<"), .xml)
    }

    // MARK: - Integration: detect from real MappedFile

    func testDetectRealJSONFile() throws {
        let json = "{\"name\": \"Alice\", \"age\": 30}"
        let url  = writeTmp(json, ext: "json")
        let file = try MappedFile(url: url)
        XCTAssertEqual(FormatDetector.detect(file: file), .json)
    }

    func testDetectRealCSVFile() throws {
        let csv = "name,age\nAlice,30\nBob,25\n"
        let url = writeTmp(csv, ext: "csv")
        let file = try MappedFile(url: url)
        XCTAssertEqual(FormatDetector.detect(file: file), .csv)
    }

    func testDetectRealYAMLFile() throws {
        let yaml = "name: Alice\nage: 30\n"
        let url  = writeTmp(yaml, ext: "yaml")
        let file = try MappedFile(url: url)
        XCTAssertEqual(FormatDetector.detect(file: file), .yaml)
    }

    func testDetectRealXMLFile() throws {
        let xml = "<?xml version=\"1.0\"?><root><item>1</item></root>"
        let url = writeTmp(xml, ext: "xml")
        let file = try MappedFile(url: url)
        XCTAssertEqual(FormatDetector.detect(file: file), .xml)
    }

    func testDetectJSONWithWrongExtension() throws {
        // Content is JSON but file is named .yaml — content should win
        let json = "[1, 2, 3]"
        let url  = writeTmp(json, ext: "yaml")
        let file = try MappedFile(url: url)
        XCTAssertEqual(FormatDetector.detect(file: file, fileExtension: "yaml"), .json)
    }

    // MARK: - Integration: round-trip via parser

    func testDetectedJSONParses() async throws {
        let json = "{\"key\": \"value\"}"
        let url  = writeTmp(json, ext: "json")
        let file = try MappedFile(url: url)
        let detected = FormatDetector.detect(file: file)
        XCTAssertEqual(detected, .json)
        let si  = try await JSONParser().buildIndex(from: file)
        let idx = si.buildNodeIndex()
        XCTAssertEqual(idx.root?.type, .object)
    }

    func testDetectedCSVParses() async throws {
        let csv = "x,y\n1,2\n3,4\n"
        let url = writeTmp(csv, ext: "csv")
        let file = try MappedFile(url: url)
        XCTAssertEqual(FormatDetector.detect(file: file), .csv)
        let si  = try await CSVParser().buildIndex(from: file)
        let idx = si.buildNodeIndex()
        XCTAssertTrue(idx.isTabular())
    }

    func testDetectedYAMLParses() async throws {
        let yaml = "- a: 1\n  b: 2\n- a: 3\n  b: 4\n"
        let url  = writeTmp(yaml, ext: "yaml")
        let file = try MappedFile(url: url)
        XCTAssertEqual(FormatDetector.detect(file: file), .yaml)
        let si  = try await YAMLParser().buildIndex(from: file)
        let idx = si.buildNodeIndex()
        XCTAssertEqual(idx.root?.type, .array)
    }

    // MARK: - Private helpers

    @discardableResult
    private func writeTmp(_ content: String, ext: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("detect-\(UUID().uuidString).\(ext)")
        try? content.data(using: .utf8)!.write(to: url)
        return url
    }
}
