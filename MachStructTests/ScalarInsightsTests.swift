import XCTest
@testable import MachStructCore

final class ScalarInsightsTests: XCTestCase {

    // MARK: - Unix timestamps

    func testUnixTimestampSeconds() {
        // 2026-04-27 ≈ 1745712000
        let n: Int64 = 1_745_712_000
        let ins = ScalarValue.integer(n).inspect()
        XCTAssertNotNil(ins?.unixTimestamp)
    }

    func testUnixTimestampMilliseconds() {
        let n: Int64 = 1_745_712_000_000
        let ins = ScalarValue.integer(n).inspect()
        XCTAssertNotNil(ins?.unixTimestamp)
    }

    func testIntegerOutOfRangeIsNotTimestamp() {
        XCTAssertNil(ScalarValue.integer(42).inspect())
        XCTAssertNil(ScalarValue.integer(1_000).inspect())
    }

    func testNumericStringTimestamp() {
        let ins = ScalarValue.string("1745712000").inspect()
        XCTAssertNotNil(ins?.unixTimestamp)
    }

    // MARK: - ISO 8601

    func testISO8601WithZ() {
        let ins = ScalarValue.string("2026-04-27T14:32:11Z").inspect()
        XCTAssertNotNil(ins?.iso8601Date)
    }

    func testISO8601WithFraction() {
        let ins = ScalarValue.string("2026-04-27T14:32:11.123Z").inspect()
        XCTAssertNotNil(ins?.iso8601Date)
    }

    func testNonISOStringNotDetected() {
        XCTAssertNil(ScalarValue.string("hello world").inspect())
    }

    // MARK: - UUID

    func testUUIDDetected() {
        let ins = ScalarValue.string("550E8400-E29B-41D4-A716-446655440000").inspect()
        XCTAssertNotNil(ins?.uuid)
    }

    func testInvalidUUIDNotDetected() {
        XCTAssertNil(ScalarValue.string("not-a-uuid-at-all-really-no").inspect()?.uuid)
    }

    // MARK: - Hex colour

    func testHexColor6() throws {
        let hex = try XCTUnwrap(ScalarValue.string("#FF8800").inspect()?.hexColor)
        XCTAssertEqual(hex.hex,   "#FF8800")
        XCTAssertEqual(hex.red,   1.0,        accuracy: 0.01)
        XCTAssertEqual(hex.green, 136/255.0,  accuracy: 0.01)
        XCTAssertEqual(hex.blue,  0.0,        accuracy: 0.01)
    }

    func testHexColor3Expansion() {
        let ins = ScalarValue.string("#abc").inspect()
        XCTAssertEqual(ins?.hexColor?.hex, "#AABBCC")
    }

    func testInvalidHexColor() {
        XCTAssertNil(ScalarValue.string("#GGGGGG").inspect()?.hexColor)
        XCTAssertNil(ScalarValue.string("#1234").inspect()?.hexColor)
    }

    // MARK: - Base64

    func testBase64Detected() {
        // "Hello, world!" base64 encoded
        let ins = ScalarValue.string("SGVsbG8sIHdvcmxkIQ==").inspect()
        XCTAssertEqual(ins?.base64Preview?.totalBytes, 13)
        XCTAssertEqual(ins?.base64Preview?.firstBytesUTF8, "Hello, world!")
    }

    func testShortStringIsNotBase64() {
        // "abcd" is technically valid base64 but too short to surface.
        XCTAssertNil(ScalarValue.string("abcd").inspect()?.base64Preview)
    }

    func testNonBase64String() {
        XCTAssertNil(ScalarValue.string("hello world!!!!").inspect()?.base64Preview)
    }

    // MARK: - Negative

    func testEmptyStringNoInsights() {
        XCTAssertNil(ScalarValue.string("").inspect())
    }

    func testBooleanNoInsights() {
        XCTAssertNil(ScalarValue.boolean(true).inspect())
    }

    func testNullNoInsights() {
        XCTAssertNil(ScalarValue.null.inspect())
    }
}
