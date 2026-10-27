import XCTest
import CSimdjsonBridge
@testable import MachStructCore

/// The byte-level scanner that large JSON files are read through (ADR-002)
/// must accept and reject exactly what simdjson does on the small-file path,
/// and describe the same tree.
final class JSONScannerTests: XCTestCase {

    // MARK: - Helpers

    private struct Validation {
        let info: MSJSONInfo?
        let error: MSJSONError?
    }

    private func validate(_ json: String) -> Validation {
        validate(Array(json.utf8))
    }

    private func validate(_ bytes: [UInt8]) -> Validation {
        var info = MSJSONInfo()
        var error = MSJSONError()
        let ok = bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(1, buf.count)) {
                ms_json_validate($0, UInt64(buf.count), &info, &error)
            }
        }
        return ok == 1 ? Validation(info: info, error: nil) : Validation(info: nil, error: error)
    }

    /// simdjson's verdict: the number of entries, or nil when it rejects.
    private func simdjsonCount(_ bytes: [UInt8]) -> Int? {
        var raw: UnsafeMutablePointer<MSIndexEntry>?
        let count = bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(1, buf.count)) {
                ms_build_structural_index_alloc($0, UInt64(buf.count), &raw)
            }
        }
        defer { ms_free_entries(raw) }
        return count >= 0 ? Int(count) : nil
    }

    private func children(_ json: String, at offset: Int) -> [Int] {
        let bytes = Array(json.utf8)
        var out = [UInt64](repeating: 0, count: 64)
        let n = bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                ms_json_child_offsets($0, UInt64(buf.count), UInt64(offset), &out, 64, nil)
            }
        }
        return out.prefix(Int(n)).map(Int.init)
    }

    private func valueInfo(_ json: String, at offset: Int) -> MSJSONValue {
        let bytes = Array(json.utf8)
        var out = MSJSONValue()
        bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                ms_json_value_info($0, UInt64(buf.count), UInt64(offset), &out)
            }
        }
        return out
    }

    // MARK: - Validation

    func testValidDocumentsAreAcceptedWithTheirNodeCount() {
        let docs = [
            "{}", "[]", "0", "-1.5e+10", "\"\"", "true", "null",
            #"{"a":1,"b":[true,false,null],"c":{"d":"x"}}"#,
            " \n\t[ 1 , [ ] , { } ] \r\n",
            #"["é😀\n\"\\\/"]"#,
            "[\"é😀\"]",
            #"{"a":{"a":{"a":{"a":[[[[[]]]]]}}}}"#,
        ]
        for doc in docs {
            let v = validate(doc)
            XCTAssertNotNil(v.info, "\(doc): \(v.error.map { String(cString: $0.message) } ?? "")")
            XCTAssertEqual(v.info.map { Int($0.node_count) }, simdjsonCount(Array(doc.utf8)), doc)
        }
    }

    func testRootFacts() throws {
        let info = try XCTUnwrap(validate(#"  {"a":[1,2],"b":3}  "#).info)
        XCTAssertEqual(info.root_offset, 2)
        XCTAssertEqual(info.root_end, 19)
        XCTAssertEqual(info.root_type, UInt8(MS_NODE_TYPE_OBJECT))
        XCTAssertEqual(info.root_child_count, 2)
    }

    func testALeadingByteOrderMarkIsSkipped() throws {
        let info = try XCTUnwrap(validate([0xEF, 0xBB, 0xBF] + Array("[1]".utf8)).info)
        XCTAssertEqual(info.root_offset, 3)
    }

    func testInvalidDocumentsAreRejectedAtTheProblem() {
        let cases: [(String, Int)] = [
            ("", 0), ("   ", 3), ("[1,]", 3), (#"{"a":1,}"#, 7), ("[1 2]", 3),
            (#"{"a" 1}"#, 5), ("{1:2}", 1), ("[01]", 2), ("[1.]", 1), ("[-]", 1),
            ("[1e]", 1), ("[tru]", 1), ("[nul", 1), (#"["abc"#, 1), ("[1]x", 3),
            (#"["\x"]"#, 2), (#"["\u12g4"]"#, 2), (#"["\ud800"]"#, 2), (#"["\udc00"]"#, 2),
            ("[\"\u{01}\"]", 2), ("[1", 2), ("{", 1), ("}", 0), ("[]]", 2),
        ]
        for (doc, offset) in cases {
            let v = validate(doc)
            XCTAssertNil(v.info, "accepted \(doc)")
            XCTAssertEqual(v.error.map { Int($0.offset) }, offset, doc)
            XCTAssertNil(simdjsonCount(Array(doc.utf8)), "simdjson accepts \(doc)")
        }
    }

    func testInvalidUTF8IsRejected() {
        for bad: [UInt8] in [[0xC0, 0x80], [0xED, 0xA0, 0x80], [0xF5, 0x80, 0x80, 0x80], [0xE2, 0x82]] {
            let doc = Array("[\"".utf8) + bad + Array("\"]".utf8)
            XCTAssertNil(validate(doc).info, "\(bad)")
            XCTAssertNil(simdjsonCount(doc), "simdjson accepts \(bad)")
        }
    }

    func testAgreesWithSimdjsonOnMutatedDocuments() {
        var rng = SystemRandomNumberGenerator()
        let seeds = [
            #"{"name":"Alice","tags":["a","b"],"n":-12.5e3,"ok":true,"x":null,"o":{"k":[1,{"z":"é"}]}}"#,
            #"[{"id":1,"v":"x\"y"},{"id":2,"v":[]},{"id":3,"v":{}}]"#,
        ]
        let alphabet = Array(#"{}[],:"\ 0123456789-+.eEtrufalsn\u"#.utf8) + [0x0A, 0xC3, 0xA9]
        for seed in seeds {
            for _ in 0..<3_000 {
                var bytes = Array(seed.utf8)
                for _ in 0..<Int.random(in: 1...3, using: &rng) {
                    let i = Int.random(in: 0..<bytes.count, using: &rng)
                    switch Int.random(in: 0..<3, using: &rng) {
                    case 0: bytes.remove(at: i)
                    case 1: bytes.insert(alphabet.randomElement(using: &rng)!, at: i)
                    default: bytes[i] = alphabet.randomElement(using: &rng)!
                    }
                    if bytes.isEmpty { bytes = [0x30] }
                }
                let ours = validate(bytes).info.map { Int($0.node_count) }
                XCTAssertEqual(ours, simdjsonCount(bytes), String(decoding: bytes, as: UTF8.self))
            }
        }
    }

    // MARK: - Reading the tree

    func testChildOffsetsOfObjectsAreTheirKeysAndOfArraysTheirElements() {
        let json = #"{"a":[1, "x" ,{}],"b":2}"#
        XCTAssertEqual(children(json, at: 0), [1, 18])
        XCTAssertEqual(children(json, at: 5), [6, 9, 14])
        XCTAssertEqual(children("[ ]", at: 0), [])
        XCTAssertEqual(children("1", at: 0), [])
    }

    func testValueInfo() {
        let json = #"{"a":[1,"]",{"b":"}"}],"c":12}"#
        let array = valueInfo(json, at: 5)
        XCTAssertEqual(array.type, UInt8(MS_NODE_TYPE_ARRAY))
        XCTAssertEqual(array.end, 22)
        XCTAssertEqual(array.child_count, 3)
        let number = valueInfo(json, at: 27)
        XCTAssertEqual(number.type, UInt8(MS_NODE_TYPE_NUMBER))
        XCTAssertEqual(number.end, 29)
        XCTAssertEqual(valueInfo(json, at: 0).child_count, 2)
    }

    func testMemberFindsTheValueAfterTheColon() {
        let bytes = Array(#"{ "k\"ey" : true }"#.utf8)
        var keyEnd: UInt64 = 0, valueOffset: UInt64 = 0
        bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                ms_json_member($0, UInt64(buf.count), 2, &keyEnd, &valueOffset)
            }
        }
        XCTAssertEqual(keyEnd, 9)
        XCTAssertEqual(valueOffset, 12)
    }

    func testCorpusFilesValidateLikeSimdjson() async throws {
        let corpus = TestCorpusGenerator()
        try corpus.prepare()
        for kind in [TestCorpusGenerator.Corpus.tiny, .medium, .large, .pathologicalDeep,
                     .pathologicalWide] {
            let file = try MappedFile(url: corpus.url(for: kind))
            var info = MSJSONInfo(), error = MSJSONError()
            let ok = ms_json_validate(file.rawPointer.assumingMemoryBound(to: CChar.self),
                                      file.fileSize, &info, &error)
            XCTAssertEqual(ok, 1, "\(kind)")
            let si = try await JSONParser().buildIndex(from: file)
            XCTAssertEqual(Int(info.node_count), si.count, "\(kind)")
        }
    }
}
