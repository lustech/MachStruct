import XCTest
@testable import MachStructCore

/// A file that fails to parse must say what is wrong and where, in the
/// user's terms — not a library name or error number (#26).
final class ParseErrorTests: XCTestCase {

    private func parseError(_ text: String, ext: String,
                            _ parser: any StructParser) async throws -> ParseError {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parse-error-\(UUID().uuidString).\(ext)")
        try Data(text.utf8).write(to: url)
        do {
            _ = try await parser.buildIndex(from: MappedFile(url: url))
        } catch let error as ParseError {
            return error
        } catch {
            XCTFail("expected ParseError, got \(type(of: error)): \(error)")
            throw error
        }
        XCTFail("expected the parse to fail")
        throw CancellationError()
    }

    // MARK: - JSON

    func testJSONReportsLineColumnAndExcerpt() async throws {
        let error = try await parseError(#"{"a": 1,, "b": 2}"#, ext: "json", JSONParser())
        XCTAssertEqual(error.line, 1)
        XCTAssertEqual(error.column, 9)
        XCTAssertEqual(error.excerpt, "{\"a\": 1,, \"b\": 2}\n        ^")
        XCTAssertTrue(error.localizedDescription.hasPrefix("Line 1, column 9: "),
                      error.localizedDescription)
    }

    func testJSONPositionOnALaterLine() async throws {
        let error = try await parseError("{\n  \"a\": 1\n  \"b\": 2\n}", ext: "json", JSONParser())
        XCTAssertEqual(error.line, 3)
        XCTAssertEqual(error.column, 3)
        XCTAssertEqual(error.excerpt, "  \"b\": 2\n  ^")
    }

    func testJSONUnexpectedEndPointsPastTheLastCharacter() async throws {
        let error = try await parseError("[1, 2", ext: "json", JSONParser())
        XCTAssertEqual(error.line, 1)
        XCTAssertEqual(error.column, 6)
    }

    func testColumnsCountCharactersNotBytes() async throws {
        let error = try await parseError(#"{"ö": 1,, }"#, ext: "json", JSONParser())
        XCTAssertEqual(error.column, 9)
        XCTAssertEqual(error.excerpt, "{\"ö\": 1,, }\n        ^")
    }

    func testJSONMessageNamesNoLibrary() async throws {
        let error = try await parseError("[1, 2", ext: "json", JSONParser())
        for term in ["simdjson", "NSJSON", "Foundation", "error -"] {
            XCTAssertFalse(error.localizedDescription.contains(term), error.localizedDescription)
        }
    }

    /// A minified file is one long line; the excerpt shows the neighbourhood.
    func testExcerptOfALongLineIsWindowed() async throws {
        let json = "[" + String(repeating: "1, ", count: 300) + ",]"
        let error = try await parseError(json, ext: "json", JSONParser())
        let lines = try XCTUnwrap(error.excerpt).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertLessThan(lines[0].count, 100)
        // The caret still sits under the offending character.
        let caret = try XCTUnwrap(lines[1].firstIndex(of: "^"))
        let offset = lines[1].distance(from: lines[1].startIndex, to: caret)
        XCTAssertEqual(Array(lines[0])[offset], ",")
    }

    // MARK: - YAML

    func testYAMLReportsPositionAndProblem() async throws {
        let error = try await parseError("a: [1, 2\nb: 3\n", ext: "yaml", YAMLParser())
        XCTAssertNotNil(error.line)
        XCTAssertNotNil(error.column)
        XCTAssertNotNil(error.excerpt)
        XCTAssertFalse(error.localizedDescription.contains("Yams"), error.localizedDescription)
        XCTAssertTrue(error.localizedDescription.hasPrefix("Line "), error.localizedDescription)
    }

    func testYAMLMessageReadsAsOneSentence() async throws {
        let flow = try await parseError("a: [1, 2\nb: 3\n", ext: "yaml", YAMLParser())
        XCTAssertEqual(flow.localizedDescription,
                       "Line 2, column 2: Did not find expected ',' or ']' while parsing a flow sequence.")
        let documents = try await parseError("a: 1\n---\nb: 2\n", ext: "yaml", YAMLParser())
        XCTAssertEqual(documents.localizedDescription,
                       "Line 2, column 1: Expected a single document in the stream but found another document.")
    }

    // MARK: - XML

    func testXMLReportsPositionAndProblem() async throws {
        let error = try await parseError("<a>\n<b></a>", ext: "xml", XMLParser())
        XCTAssertEqual(error.line, 2)
        XCTAssertNotNil(error.column)
        XCTAssertFalse(error.localizedDescription.contains("NSXMLParserErrorDomain"),
                       error.localizedDescription)
        XCTAssertTrue(error.localizedDescription.contains("mismatch"), error.localizedDescription)
    }
}
