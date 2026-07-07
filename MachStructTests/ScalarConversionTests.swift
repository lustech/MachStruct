import XCTest
@testable import MachStructCore

/// Regression tests for the 0/1-as-Bool coercion bug.
///
/// `NSNumber(0)` / `NSNumber(1)` cast to Swift `Bool` successfully, so any
/// conversion that checks `as? Bool` before `CFBooleanGetTypeID` turns the
/// JSON numbers `0` and `1` into `false`/`true` — corrupting display *and*
/// re-serialization on save.
final class ScalarConversionTests: XCTestCase {

    private func makeFile(json: String) throws -> MappedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conv-test-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        return try MappedFile(url: url)
    }

    // MARK: - ScalarValue(jsonAny:) unit coverage

    func testJSONAnyConversionDistinguishesZeroOneFromBool() {
        XCTAssertEqual(ScalarValue(jsonAny: NSNumber(value: 1)), .integer(1))
        XCTAssertEqual(ScalarValue(jsonAny: NSNumber(value: 0)), .integer(0))
        XCTAssertEqual(ScalarValue(jsonAny: kCFBooleanTrue as Any), .boolean(true))
        XCTAssertEqual(ScalarValue(jsonAny: kCFBooleanFalse as Any), .boolean(false))
        XCTAssertEqual(ScalarValue(jsonAny: true), .boolean(true))
        XCTAssertEqual(ScalarValue(jsonAny: NSNumber(value: 3.14)), .float(3.14))
        XCTAssertEqual(ScalarValue(jsonAny: NSNumber(value: Int64.max)),
                       .integer(Int64.max))
        XCTAssertEqual(ScalarValue(jsonAny: "x"), .string("x"))
        XCTAssertEqual(ScalarValue(jsonAny: NSNull()), .null)
    }

    /// JSONSerialization parses unsigned 64-bit numbers ≥ 2^63 as UInt64-typed
    /// NSNumbers; these must not bit-wrap to negative Int64.
    func testUInt64BeyondInt64DoesNotWrapNegative() throws {
        let any = try JSONSerialization.jsonObject(
            with: #"{"big": 9223372036854775808}"#.data(using: .utf8)!)
        let dict = try XCTUnwrap(any as? [String: Any])
        let sv = ScalarValue(jsonAny: try XCTUnwrap(dict["big"]))
        switch sv {
        case .integer(let i):
            XCTFail("2^63 wrapped to Int64: \(i)")
        case .float(let d):
            XCTAssertEqual(d, 9.223372036854776e18, accuracy: 1e4)
        default:
            XCTFail("unexpected: \(sv)")
        }
        // In-range values keep exactness.
        XCTAssertEqual(ScalarValue(jsonAny: NSNumber(value: UInt64(42))), .integer(42))
    }

    // MARK: - Foundation parse path (files < 5 MB)

    func testFoundationPathParsesZeroAndOneAsIntegers() async throws {
        let file = try makeFile(json: #"{"a":1,"b":0,"c":true,"d":false,"e":2}"#)
        let si = try await JSONParser().buildIndex(from: file)

        func value(forKey key: String) -> ScalarValue? {
            guard let kv = si.entries.first(where: { $0.key == key }) else { return nil }
            return si.entries.first { $0.parentID == kv.id }?.parsedValue
        }

        XCTAssertEqual(value(forKey: "a"), .integer(1))
        XCTAssertEqual(value(forKey: "b"), .integer(0))
        XCTAssertEqual(value(forKey: "c"), .boolean(true))
        XCTAssertEqual(value(forKey: "d"), .boolean(false))
        XCTAssertEqual(value(forKey: "e"), .integer(2))
    }

    /// Round-trip: a document containing 0/1 must serialize back as numbers.
    func testSerializationRoundTripPreservesZeroAndOne() async throws {
        let file = try makeFile(json: #"{"count":1,"offset":0}"#)
        let si = try await JSONParser().buildIndex(from: file)
        let idx = si.buildNodeIndex()

        let data = try JSONDocumentSerializer(index: idx, mappedFile: file)
            .serialize(pretty: false)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("true"), "1 re-serialized as true: \(text)")
        XCTAssertFalse(text.contains("false"), "0 re-serialized as false: \(text)")
        XCTAssertTrue(text.contains(#""count":1"#), "got: \(text)")
        XCTAssertTrue(text.contains(#""offset":0"#), "got: \(text)")
    }

    // MARK: - Lazy scalar parse (SearchEngine byte path)

    func testSearchEngineParsesZeroOneBytesAsIntegers() throws {
        let json = #"{"a":1}"#
        let file = try makeFile(json: json)

        // Hand-build simdjson-shaped entries (nil key/parsedValue, real byte
        // ranges): root object, kv "a" (bytes 1..3 = "a" quoted), scalar 1 at
        // byte 5.
        let rootID = NodeID.generate()
        let kvID = NodeID.generate()
        let valID = NodeID.generate()
        let entries = [
            IndexEntry(id: rootID, byteOffset: 0, byteLength: 7,
                       nodeType: .object, depth: 0, parentID: nil, childCount: 1),
            IndexEntry(id: kvID, byteOffset: 1, byteLength: 3,
                       nodeType: .keyValue, depth: 1, parentID: rootID, childCount: 1),
            IndexEntry(id: valID, byteOffset: 5, byteLength: 1,
                       nodeType: .scalar, depth: 2, parentID: kvID, childCount: 0),
        ]
        let si = StructuralIndex(entries: entries)

        let matches = SearchEngine.search(query: "1", in: si, file: file)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.matchedText, "1",
                       "scalar byte '1' must parse as integer, not boolean")
    }

    // MARK: - Clipboard paste path

    func testClipboardInsertPreservesZeroAndOne() throws {
        let root = DocumentNode(type: .array, value: .container(childCount: 0))
        let index = NodeIndex(root: root)

        let json = try JSONSerialization.jsonObject(
            with: #"[1,0,true]"#.data(using: .utf8)!, options: .allowFragments)
        let tx = try XCTUnwrap(EditTransaction.insertFromClipboard(
            json, into: root.id, in: index))

        let scalars = tx.afterSnapshot.values
            .filter { $0.type == .scalar }
            .compactMap { node -> ScalarValue? in
                if case .scalar(let sv) = node.value { return sv }
                return nil
            }
        XCTAssertEqual(scalars.count, 3)
        XCTAssertTrue(scalars.contains(.integer(1)), "scalars: \(scalars)")
        XCTAssertTrue(scalars.contains(.integer(0)), "scalars: \(scalars)")
        XCTAssertTrue(scalars.contains(.boolean(true)), "scalars: \(scalars)")
    }
}
