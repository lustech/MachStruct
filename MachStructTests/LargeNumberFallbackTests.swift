import XCTest
@testable import MachStructCore

/// Regression tests for issue #25.
///
/// simdjson rejects integer literals beyond `UInt64.max`. Once #17 routed the
/// structural walk through simdjson at every file size, such a document failed
/// to open at all — one oversized number made the whole file unreadable, where
/// 2.1.0 had opened it fine via the Foundation walk.
final class LargeNumberFallbackTests: XCTestCase {

    private func parse(_ json: String) async throws -> (StructuralIndex, MappedFile) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bignum-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        let file = try MappedFile(url: url)
        return (try await JSONParser().buildIndex(from: file), file)
    }

    private func scalarValue(_ si: StructuralIndex, file: MappedFile) -> ScalarValue? {
        guard let entry = si.entries.first(where: { $0.nodeType == .scalar }) else { return nil }
        if let parsed = entry.parsedValue { return parsed }
        guard entry.byteLength > 0 else { return nil }
        return JSONParser.decodeScalarToken(
            at: (offset: entry.byteOffset, length: entry.byteLength), in: file)
    }

    // MARK: - The regression

    func testIntegerBeyondUInt64MaxStillOpens() async throws {
        let (si, file) = try await parse(#"{"v":123456789012345678901234567890}"#)
        let value = try XCTUnwrap(scalarValue(si, file: file))
        guard case .float(let d) = value else {
            return XCTFail("expected a float, got \(value)")
        }
        XCTAssertEqual(d, 1.2345678901234568e+29, accuracy: 1e14)
    }

    func testOneAboveUInt64MaxStillOpens() async throws {
        let (si, file) = try await parse(#"{"v":18446744073709551616}"#)
        let value = try XCTUnwrap(scalarValue(si, file: file))
        guard case .float(let d) = value else {
            return XCTFail("expected a float, got \(value)")
        }
        XCTAssertEqual(d, 18446744073709551616.0, accuracy: 1e5)
    }

    /// The boundary value itself was always fine; keep it that way.
    func testUInt64MaxStillParses() async throws {
        let (si, file) = try await parse(#"{"v":18446744073709551615}"#)
        XCTAssertNotNil(scalarValue(si, file: file))
    }

    /// A big number alongside ordinary data must not disturb the rest.
    func testDocumentWithBigNumberKeepsItsOtherValues() async throws {
        let (si, file) = try await parse(
            #"{"id":123456789012345678901234567890,"name":"ok","n":7}"#)
        let keys = si.entries.filter { $0.nodeType == .keyValue }.compactMap { entry -> String? in
            if let k = entry.key { return k }
            guard entry.byteLength > 0,
                  let bytes = try? file.slice(offset: entry.byteOffset,
                                              length: entry.byteLength)
            else { return nil }
            return JSONParser.decodeStringToken(bytes)
        }
        XCTAssertEqual(keys, ["id", "name", "n"])
    }

    // MARK: - Genuinely broken input must still fail

    func testMalformedJSONStillThrows() async throws {
        do {
            _ = try await parse(#"{"a": 1,, "b": [1,2,}"#)
            XCTFail("malformed JSON should not parse")
        } catch {
            // expected
        }
    }

    func testTruncatedJSONStillThrows() async throws {
        do {
            _ = try await parse(#"{"a": 1"#)
            XCTFail("truncated JSON should not parse")
        } catch {
            // expected
        }
    }

    // MARK: - Large files

    /// Files at or above the eager threshold take the same bridge path, so the
    /// fallback has to cover them too.
    func testBigNumberInLargeFileStillOpens() async throws {
        var json = #"{"id":123456789012345678901234567890,"pad":["#
        json += (0..<400_000).map { "\"padpadpadpad\($0)\"" }.joined(separator: ",")
        json += "]}"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bignum-big-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        let file = try MappedFile(url: url)
        XCTAssertGreaterThan(file.fileSize, JSONParser.eagerResolveThreshold)

        let si = try await JSONParser().buildIndex(from: file)
        XCTAssertGreaterThan(si.entries.count, 400_000,
                             "the document should be fully indexed")
    }
}
