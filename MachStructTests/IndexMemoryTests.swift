import XCTest
import CSimdjsonBridge
@testable import MachStructCore

/// The structural index of a large file holds millions of entries, so its
/// layout and how it is built decide how much memory a file takes (#62).
final class IndexMemoryTests: XCTestCase {

    private func file(_ text: String, ext: String) throws -> MappedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("index-memory-\(UUID().uuidString).\(ext)")
        try Data(text.utf8).write(to: url)
        return try MappedFile(url: url)
    }

    private func children(_ si: StructuralIndex, _ i: Int) -> [Int] {
        Array(si.childIndices[si.entries[i].id] ?? [])
    }

    // MARK: - Entry layout

    func testEntriesStayCompact() {
        // 136 bytes with format metadata stored inline; 88 with it boxed.
        XCTAssertLessThanOrEqual(MemoryLayout<IndexEntry>.stride, 88)
    }

    func testCSVCellsShareTheirColumnsMetadata() async throws {
        let si = try await CSVParser().buildIndex(from: file("a,b\n1,2\n3,4\n", ext: "csv"))
        let cells = si.entries.filter { $0.nodeType == .scalar }

        let columns = cells.map { entry -> Int? in
            guard case .csv(let meta)? = entry.metadata else { return nil }
            return meta.columnIndex
        }
        XCTAssertEqual(columns, [0, 1, 0, 1])
    }

    // MARK: - Child table

    func testChildrenAreListedInDocumentOrder() async throws {
        // 0 {  1 "a"  2 [  3 1  4 2 ]  5 "b"  6 3 }
        let si = try await JSONParser().buildIndex(from: file(#"{"a":[1,2],"b":3}"#, ext: "json"))

        XCTAssertEqual(children(si, 0), [1, 5])
        XCTAssertEqual(children(si, 1), [2])
        XCTAssertEqual(children(si, 2), [3, 4])
    }

    func testLeavesAndUnknownIDsHaveNoChildren() async throws {
        let si = try await JSONParser().buildIndex(from: file("[1]", ext: "json"))

        XCTAssertNil(si.childIndices[si.entries[1].id])
        XCTAssertNil(si.childIndices[NodeID.generate()])
    }

    // MARK: - CSV IDs

    func testCSVRowsWiderThanTheHeaderGetIDsFromTheDocumentsBlock() async throws {
        let si = try await CSVParser().buildIndex(from: file("a\n1,2,3\n4\n", ext: "csv"))

        let base = try XCTUnwrap(si.entries.first).id.rawValue
        XCTAssertEqual(si.entries.map(\.id.rawValue), (0..<UInt64(si.count)).map { base + $0 })
        let firstRow = children(si, 1)
        XCTAssertEqual(firstRow.map { si.entries[$0].key }, ["a", "column_2", "column_3"])
    }

    func testCSVWithoutHeaderAcceptsRowsWiderThanTheFirst() async throws {
        let si = try await CSVParser().buildIndex(from: file("1,2\n3,4,5\n", ext: "csv"))

        let secondRow = children(si, 0)[1]
        XCTAssertEqual(children(si, secondRow).count, 3)
    }

    // MARK: - simdjson bridge

    func testSelfSizingBridgeMatchesTheCallerSizedOne() throws {
        let json = #"{"a":[1,{"b":null}],"c":"x","d":[[]]}"#
        var sized = [MSIndexEntry](repeating: MSIndexEntry(), count: 100)
        let sizedCount = json.withCString {
            ms_build_structural_index($0, UInt64(json.utf8.count), &sized, 100)
        }

        var raw: UnsafeMutablePointer<MSIndexEntry>?
        let count = json.withCString {
            ms_build_structural_index_alloc($0, UInt64(json.utf8.count), &raw)
        }
        defer { ms_free_entries(raw) }

        XCTAssertEqual(count, sizedCount)
        let entries = Array(UnsafeBufferPointer(start: raw, count: Int(count)))
        func fields(_ e: MSIndexEntry) -> [Int64] {
            [Int64(e.byte_length), Int64(e.node_type), Int64(e.depth),
             e.parent_index, Int64(e.child_count)]
        }
        XCTAssertEqual(entries.map(fields), sized.prefix(Int(sizedCount)).map(fields))
    }

    func testSelfSizingBridgeRejectsInvalidJSON() {
        var raw: UnsafeMutablePointer<MSIndexEntry>?
        let count = "{ nope".withCString { ms_build_structural_index_alloc($0, 6, &raw) }

        XCTAssertEqual(count, Int64(MS_ERROR_PARSE_FAILED))
        XCTAssertNil(raw)
    }

    // MARK: - Progress

    func testProgressReportsCountsThatAddUpToTheIndex() async throws {
        let f = try file("[" + (0..<2_500).map(String.init).joined(separator: ",") + "]", ext: "json")
        var reported = 0
        var total = 0
        for await progress in JSONParser().parseProgressively(file: f) {
            switch progress {
            case .nodesIndexed(let count): reported += count
            case .complete(let si):        total = si.count
            case .error(let e):            XCTFail("\(e)")
            case .warning:                 break
            }
        }
        XCTAssertEqual(reported, 2_501)
        XCTAssertEqual(total, 2_501)
    }
}
