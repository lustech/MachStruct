import XCTest
@testable import MachStructCore

/// Regression tests for issues #13 (key order) and #15 (duplicate keys).
///
/// Both came from routing object structure through `JSONSerialization`, whose
/// `NSDictionary` cannot represent either property: it has no insertion order
/// and no repeated keys. The structural walk now reads the byte stream, so the
/// index reflects what is actually in the file.
final class ObjectKeyFidelityTests: XCTestCase {

    private func makeFile(json: String) throws -> MappedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fidelity-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        return try MappedFile(url: url)
    }

    /// Keys of the given object entry's children, in index order.
    private func keys(of si: StructuralIndex, file: MappedFile) -> [String] {
        si.entries.filter { $0.nodeType == .keyValue }.compactMap { entry -> String? in
            if let key = entry.key { return key }
            guard entry.byteLength > 0,
                  let bytes = try? file.slice(offset: entry.byteOffset,
                                              length: entry.byteLength)
            else { return nil }
            return JSONParser.decodeStringToken(bytes)
        }
    }

    // MARK: - #13 key order

    func testObjectKeyOrderIsPreserved() async throws {
        let file = try makeFile(json:
            #"{"score": 1.0, "flag": true, "ratio": 1.5, "n": 1, "name": "x"}"#)
        let si = try await JSONParser().buildIndex(from: file)
        XCTAssertEqual(keys(of: si, file: file),
                       ["score", "flag", "ratio", "n", "name"])
    }

    /// Keys chosen so that hash order is very unlikely to match document order.
    func testKeyOrderPreservedForManyKeys() async throws {
        let expected = (0..<60).map { "key_\($0)_\(UUID().uuidString.prefix(4))" }
        let json = "{" + expected.map { #""\#($0)": 1"# }.joined(separator: ",") + "}"
        let file = try makeFile(json: json)
        let si = try await JSONParser().buildIndex(from: file)
        XCTAssertEqual(keys(of: si, file: file), expected)
    }

    func testNestedObjectsKeepTheirOwnOrder() async throws {
        let file = try makeFile(json:
            #"{"outer":{"z":1,"a":2,"m":3},"after":{"q":1,"b":2}}"#)
        let si = try await JSONParser().buildIndex(from: file)
        XCTAssertEqual(keys(of: si, file: file),
                       ["outer", "z", "a", "m", "after", "q", "b"])
    }

    /// Order must hold on the lazy path too (>= 5 MB), where keys resolve from
    /// bytes rather than being stored on the entry.
    func testKeyOrderPreservedOnLazyPath() async throws {
        var json = #"{"score":1.0,"flag":true,"ratio":1.5,"pad":["#
        json += (0..<400_000).map { "\"padpadpadpad\($0)\"" }.joined(separator: ",")
        json += "]}"
        let file = try makeFile(json: json)
        XCTAssertGreaterThan(file.fileSize, JSONParser.eagerResolveThreshold)

        let si = try await JSONParser().buildIndex(from: file)
        XCTAssertEqual(Array(keys(of: si, file: file).prefix(4)),
                       ["score", "flag", "ratio", "pad"])
    }

    // MARK: - #15 duplicate keys

    func testDuplicateKeysArePreserved() async throws {
        let file = try makeFile(json: #"{"a":1,"a":2,"a":true,"b":9}"#)
        let si = try await JSONParser().buildIndex(from: file)
        XCTAssertEqual(keys(of: si, file: file), ["a", "a", "a", "b"])
    }

    /// Each occurrence must keep its own value, not collapse onto the last.
    func testDuplicateKeysKeepTheirOwnValues() async throws {
        let file = try makeFile(json: #"{"a":1,"a":2,"a":true}"#)
        let si = try await JSONParser().buildIndex(from: file)

        let values: [ScalarValue] = si.entries
            .filter { $0.nodeType == .keyValue }
            .compactMap { kv in
                si.entries.first { $0.parentID == kv.id }?.parsedValue
            }
        XCTAssertEqual(values, [.integer(1), .integer(2), .boolean(true)])
    }

    /// The same document must read identically either side of the 5 MB
    /// eager/lazy boundary — the size-dependent split was the bug.
    func testSmallAndLargeFilesAgreeOnDuplicatesAndOrder() async throws {
        let head = #""a":1,"a":2,"a":true,"b":9"#

        let small = try makeFile(json: "{\(head)}")
        XCTAssertLessThan(small.fileSize, JSONParser.eagerResolveThreshold)

        var bigJSON = "{\(head),\"pad\":["
        bigJSON += (0..<400_000).map { "\"padpadpadpad\($0)\"" }.joined(separator: ",")
        bigJSON += "]}"
        let big = try makeFile(json: bigJSON)
        XCTAssertGreaterThan(big.fileSize, JSONParser.eagerResolveThreshold)

        let siSmall = try await JSONParser().buildIndex(from: small)
        let siBig = try await JSONParser().buildIndex(from: big)

        XCTAssertEqual(keys(of: siSmall, file: small), ["a", "a", "a", "b"])
        XCTAssertEqual(Array(keys(of: siBig, file: big).prefix(4)),
                       ["a", "a", "a", "b"])
    }

    // MARK: - Existing contracts must not regress

    /// Array elements carry their index at parse time as `key` on the eager
    /// path. Paths use the element's position instead, which edits keep right.
    func testArrayElementsKeepIndexKeys() async throws {
        let file = try makeFile(json: #"{"items":["a","b","c"]}"#)
        let si = try await JSONParser().buildIndex(from: file)
        let elementKeys = si.entries
            .filter { $0.nodeType == .scalar && $0.key != nil }
            .compactMap(\.key)
        XCTAssertEqual(elementKeys, ["0", "1", "2"])
    }

    func testScalarValuesStillResolveEagerlyForSmallFiles() async throws {
        let file = try makeFile(json:
            #"{"s":"x","i":7,"f":1.0,"t":true,"n":null}"#)
        let si = try await JSONParser().buildIndex(from: file)

        func value(forKey key: String) -> ScalarValue? {
            guard let kv = si.entries.first(where: { $0.key == key }) else { return nil }
            return si.entries.first { $0.parentID == kv.id }?.parsedValue
        }
        XCTAssertEqual(value(forKey: "s"), .string("x"))
        XCTAssertEqual(value(forKey: "i"), .integer(7))
        XCTAssertEqual(value(forKey: "f"), .float(1.0))
        XCTAssertEqual(value(forKey: "t"), .boolean(true))
        XCTAssertEqual(value(forKey: "n"), .null)
    }

    func testEscapedAndUnicodeKeysDecodeCorrectly() async throws {
        let file = try makeFile(json:
            #"{"a\"b":1,"tab\tkey":2,"ünïcode":3,"emoji🎉":4}"#)
        let si = try await JSONParser().buildIndex(from: file)
        XCTAssertEqual(keys(of: si, file: file),
                       ["a\"b", "tab\tkey", "ünïcode", "emoji🎉"])
    }
}
