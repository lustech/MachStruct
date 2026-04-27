import XCTest
@testable import MachStructCore

final class JSONAutoFixerTests: XCTestCase {

    private func fix(_ s: String) -> JSONAutoFixer.Result {
        JSONAutoFixer.fix(Data(s.utf8))
    }

    private func fixedString(_ s: String) -> String {
        String(data: fix(s).fixed, encoding: .utf8) ?? ""
    }

    // MARK: - Trailing commas

    func testTrailingCommaInObject() {
        let r = fix(#"{"a":1,}"#)
        XCTAssertEqual(String(data: r.fixed, encoding: .utf8), #"{"a":1}"#)
        XCTAssertTrue(r.fixesApplied.contains(.trailingComma))
    }

    func testTrailingCommaInArray() {
        XCTAssertEqual(fixedString("[1, 2, 3,]"), "[1, 2, 3]")
    }

    func testNonTrailingCommaUntouched() {
        let r = fix(#"{"a":1,"b":2}"#)
        XCTAssertEqual(String(data: r.fixed, encoding: .utf8), #"{"a":1,"b":2}"#)
        XCTAssertFalse(r.fixesApplied.contains(.trailingComma))
    }

    // MARK: - Single-quoted strings

    func testSingleQuotedKeyAndValue() {
        let r = fix("{'a': 'hi'}")
        XCTAssertEqual(String(data: r.fixed, encoding: .utf8), #"{"a": "hi"}"#)
        XCTAssertTrue(r.fixesApplied.contains(.singleQuotedString))
    }

    func testSingleQuotedEscapesInternalDoubleQuote() {
        let r = fix(#"{'msg': 'he said "hi"'}"#)
        XCTAssertEqual(String(data: r.fixed, encoding: .utf8), #"{"msg": "he said \"hi\""}"#)
    }

    // MARK: - Unquoted keys

    func testUnquotedSimpleKey() {
        let r = fix("{a: 1}")
        XCTAssertEqual(String(data: r.fixed, encoding: .utf8), #"{"a": 1}"#)
        XCTAssertTrue(r.fixesApplied.contains(.unquotedKey))
    }

    func testUnquotedMultipleKeys() {
        XCTAssertEqual(fixedString("{a: 1, b: 2}"), #"{"a": 1, "b": 2}"#)
    }

    func testQuotedKeyUntouched() {
        let r = fix(#"{"a": 1}"#)
        XCTAssertFalse(r.fixesApplied.contains(.unquotedKey))
    }

    // MARK: - Comments

    func testLineComment() {
        let r = fix("{\"a\":1} // trailing\n")
        XCTAssertEqual(String(data: r.fixed, encoding: .utf8), "{\"a\":1} \n")
        XCTAssertTrue(r.fixesApplied.contains(.lineComment))
    }

    func testBlockComment() {
        let r = fix("/*c*/{\"a\":1}")
        XCTAssertEqual(String(data: r.fixed, encoding: .utf8), "{\"a\":1}")
        XCTAssertTrue(r.fixesApplied.contains(.blockComment))
    }

    // MARK: - Stray semicolons

    func testStraySemicolon() {
        let r = fix(#"{"a":1};"#)
        XCTAssertEqual(String(data: r.fixed, encoding: .utf8), #"{"a":1}"#)
        XCTAssertTrue(r.fixesApplied.contains(.straySemicolon))
    }

    // MARK: - Combined

    func testCombinedFixes() {
        let input = """
        // header
        { a: 'one', b: 2, /* note */ c: [1, 2,], }
        """
        let r = fix(input)
        let out = String(data: r.fixed, encoding: .utf8) ?? ""
        // Should parse as valid JSON.
        let data = Data(out.utf8)
        let obj = try? JSONSerialization.jsonObject(with: data, options: [])
        XCTAssertNotNil(obj, "auto-fixed output failed JSONSerialization parse: \(out)")
    }

    // MARK: - String content untouched

    func testStringContentPreservesSpecials() {
        let input = #"{"path": "/usr/bin", "msg": "a, b,]"}"#
        let r = fix(input)
        XCTAssertEqual(String(data: r.fixed, encoding: .utf8), input)
        XCTAssertTrue(r.fixesApplied.isEmpty)
    }

    func testEscapedQuoteInString() {
        let input = #"{"a": "she said \"hi\""}"#
        let r = fix(input)
        XCTAssertEqual(String(data: r.fixed, encoding: .utf8), input)
    }

    // MARK: - No-op

    func testStrictJSONUnchanged() {
        let input = #"{"a":[1,2,3],"b":{"c":true}}"#
        let r = fix(input)
        XCTAssertEqual(String(data: r.fixed, encoding: .utf8), input)
        XCTAssertTrue(r.fixesApplied.isEmpty)
        XCTAssertFalse(r.didChange)
    }
}
