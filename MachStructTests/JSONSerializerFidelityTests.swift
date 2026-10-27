import XCTest
@testable import MachStructCore

/// Regression tests for issues #29 and #31.
///
/// `JSONDocumentSerializer` used to build a Foundation object tree and hand it
/// to `JSONSerialization`. A `[String: Any]` cannot express key order or a
/// repeated key, and Foundation prints doubles at full precision — so saving
/// reordered keys, dropped duplicates, and rewrote `8.7` as
/// `8.6999999999999993`. The raw view renders through the same serializer, so
/// the damage was visible before anything was even saved.
final class JSONSerializerFidelityTests: XCTestCase {

    private func serialize(_ json: String, pretty: Bool = false) async throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ser-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        let file = try MappedFile(url: url)
        let si = try await JSONParser().buildIndex(from: file)
        let data = try JSONDocumentSerializer(index: si.buildNodeIndex(),
                                              mappedFile: file).serialize(pretty: pretty)
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - #29 key order and duplicates

    func testKeyOrderIsPreserved() async throws {
        let src = #"{"zebra":1,"apple":2,"mango":3,"banana":4,"cherry":5}"#
        let out = try await serialize(src)
        XCTAssertEqual(out, src)
    }

    func testDuplicateKeysArePreserved() async throws {
        let src = #"{"k":1,"k":2,"k":3,"other":9}"#
        let out = try await serialize(src)
        XCTAssertEqual(out, src)
    }

    func testNestedKeyOrderIsPreserved() async throws {
        let src = #"{"b":{"z":1,"a":2},"a":{"y":3,"b":4}}"#
        let out = try await serialize(src)
        XCTAssertEqual(out, src)
    }

    // MARK: - #31 number fidelity

    func testDecimalsAreNotMangled() async throws {
        let src = #"{"a":8.7,"b":14.2,"c":0.15,"d":3.4,"e":5.2,"f":11.5}"#
        let out = try await serialize(src)
        XCTAssertEqual(out, src)
    }

    func testWholeValuedFloatsKeepTheirDecimalPoint() async throws {
        let src = #"{"a":1.0,"b":0.0,"c":-2.0}"#
        let out = try await serialize(src)
        XCTAssertEqual(out, src)
    }

    func testIntegersStayIntegers() async throws {
        let src = #"{"a":1,"b":0,"c":-7,"d":9007199254740993}"#
        let out = try await serialize(src)
        XCTAssertEqual(out, src)
    }

    func testExponentsAndTinyValuesRoundTrip() async throws {
        let out = try await serialize(#"{"big":1e308,"small":1e-308}"#)
        // Reparse rather than compare text: 1e308 may render as 1e+308.
        let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: Any]
        XCTAssertEqual((obj["big"] as! NSNumber).doubleValue, 1e308)
        XCTAssertEqual((obj["small"] as! NSNumber).doubleValue, 1e-308)
    }

    // MARK: - Strings

    func testStringEscaping() async throws {
        let src = #"{"quote":"he said \"hi\"","back":"a\\b","nl":"a\nb","tab":"a\tb"}"#
        let out = try await serialize(src)
        // Must be valid JSON that reparses to the same values.
        let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: Any]
        XCTAssertEqual(obj["quote"] as? String, "he said \"hi\"")
        XCTAssertEqual(obj["back"] as? String, "a\\b")
        XCTAssertEqual(obj["nl"] as? String, "a\nb")
        XCTAssertEqual(obj["tab"] as? String, "a\tb")
    }

    func testControlCharactersAreEscaped() async throws {
        let src = #"{"c":"a\u0001b"}"#
        let out = try await serialize(src)
        XCTAssertFalse(out.contains("\u{0001}"), "raw control character must not appear")
        let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: Any]
        XCTAssertEqual(obj["c"] as? String, "a\u{0001}b")
    }

    func testUnicodeAndEmojiSurvive() async throws {
        let src = #"{"ü":"héllo 日本語","e":"🎉"}"#
        let out = try await serialize(src)
        let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: Any]
        XCTAssertEqual(obj["ü"] as? String, "héllo 日本語")
        XCTAssertEqual(obj["e"] as? String, "🎉")
    }

    // MARK: - Shapes

    func testBoolsAndNull() async throws {
        let src = #"{"t":true,"f":false,"n":null}"#
        let out = try await serialize(src)
        XCTAssertEqual(out, src)
    }

    func testEmptyContainers() async throws {
        let src = #"{"o":{},"a":[],"nested":[{}]}"#
        let out = try await serialize(src)
        XCTAssertEqual(out, src)
    }

    func testArrayRootAndNesting() async throws {
        let src = #"[1,"two",{"a":[true,null]},[]]"#
        let out = try await serialize(src)
        XCTAssertEqual(out, src)
    }

    func testScalarRootFragment() async throws {
        let s1 = try await serialize(#""just a string""#)
        XCTAssertEqual(s1, #""just a string""#)
        let s2 = try await serialize("42")
        XCTAssertEqual(s2, "42")
    }

    // MARK: - Pretty printing

    func testPrettyOutputIsValidAndOrdered() async throws {
        let src = #"{"zebra":1,"apple":{"inner":2},"list":[1,2]}"#
        let out = try await serialize(src, pretty: true)
        XCTAssertTrue(out.contains("\n"), "pretty output should be multi-line")
        // Order preserved in the text.
        let z = try XCTUnwrap(out.range(of: "zebra"))
        let a = try XCTUnwrap(out.range(of: "apple"))
        XCTAssertLessThan(z.lowerBound, a.lowerBound)
        // And it reparses.
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(out.utf8)))
    }

    // MARK: - Round trip

    func testByteExactRoundTripForCompactInput() async throws {
        let src = #"{"a":[1,2.5,"x",null,true],"b":{"c":0.0},"d":"e"}"#
        let out = try await serialize(src)
        XCTAssertEqual(out, src)
    }

    /// The lazy path (>= 5 MB) leaves scalars `.unparsed`; they are re-read from
    /// the mapped bytes and must come back with their original spelling.
    func testLargeFileValuesKeepOriginalFormatting() async throws {
        var json = #"{"a":8.7,"b":1.0,"c":"keep me","#
        json += "\"pad\":["
        json += (0..<400_000).map { "\"padpadpadpad\($0)\"" }.joined(separator: ",")
        json += "]}"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("big-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        let file = try MappedFile(url: url)
        XCTAssertGreaterThan(file.fileSize, JSONParser.eagerResolveThreshold)

        let si = try await JSONParser().buildIndex(from: file)
        let data = try JSONDocumentSerializer(index: si.buildNodeIndex(),
                                              mappedFile: file).serialize(pretty: false)
        let out = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(out.hasPrefix(#"{"a":8.7,"b":1.0,"c":"keep me","#),
                      "large-file values must keep their spelling; got \(out.prefix(60))")
    }

    /// The app saves from whatever index it currently holds. For a large file
    /// that is `buildShallowNodeIndex()`, which fills `childIDs` from the
    /// structural index *without* materialising those nodes — so a container
    /// can claim children the index cannot produce. Serializing from it used
    /// to emit `{"config":{},"services":{},"pad":[]}`: the whole document
    /// replaced by empty containers.
    func testShallowIndexSerializesTheWholeDocument() async throws {
        var json = #"{"config":{"a":1,"b":2},"services":{"s1":{"port":1}},"#
        json += "\"pad\":["
        json += (0..<400_000).map { "\"padpadpadpad\($0)\"" }.joined(separator: ",")
        json += "]}"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shallow-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        let file = try MappedFile(url: url)
        XCTAssertGreaterThan(file.fileSize, JSONParser.eagerResolveThreshold)

        let source = try JSONSource(file: file)
        var shallow = NodeIndex(root: try XCTUnwrap(source.node(for: source.rootID, parent: nil)))
        let root = try XCTUnwrap(shallow.root)
        shallow.applySnapshot(source.build([root.id: root.childIDs], in: shallow))
        XCTAssertLessThan(shallow.count, 100, "index should still be shallow")

        let data = try JSONDocumentSerializer(index: shallow, mappedFile: file, source: source)
            .serialize(pretty: false)
        let out = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertTrue(out.hasPrefix(#"{"config":{"a":1,"b":2},"services":{"s1":{"port":1}},"#),
                      "nested content must survive; got \(out.prefix(80))")
        XCTAssertFalse(out.contains(#""config":{}"#), "containers must not collapse to {}")

        // And it is still valid JSON describing the same document.
        let reparsed = try JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: Any]
        XCTAssertEqual((reparsed["pad"] as? [Any])?.count, 400_000)
    }

}
