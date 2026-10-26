import XCTest
@testable import MachStructCore

/// An array item's index is its position among its siblings, so paths stay
/// right after items are deleted or moved, and for CSV rows, which have no key.
final class ArrayIndexPathTests: XCTestCase {

    private func index(_ text: String, ext: String) async throws -> NodeIndex {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-path-\(UUID().uuidString).\(ext)")
        try Data(text.utf8).write(to: url)
        let file = try MappedFile(url: url)
        let parser: any StructParser = ext == "csv" ? CSVParser() : JSONParser()
        return try await parser.buildIndex(from: file).buildNodeIndex()
    }

    private func items(_ index: NodeIndex) throws -> [DocumentNode] {
        index.children(of: try XCTUnwrap(index.root).id)
    }

    private func value(_ node: DocumentNode) -> NodeValue { node.value }

    // MARK: - JSON arrays after edits

    func testDeletingAnItemRenumbersThePathsAfterIt() async throws {
        var idx = try await index(#"["a","b","c"]"#, ext: "json")
        let first = try items(idx)[0]
        idx = try XCTUnwrap(EditTransaction.removeNode(first.id, in: idx)).applying(to: idx)

        let c = try items(idx)[1]
        XCTAssertEqual(c.value, .scalar(.string("c")))
        XCTAssertEqual(idx.pathString(to: c.id), "root[1]")
        XCTAssertEqual(idx.resolvePath("root[0]"), try items(idx)[0].id)
    }

    func testMovingAnItemGivesItItsNewIndex() async throws {
        var idx = try await index(#"["a","b","c"]"#, ext: "json")
        let root = try XCTUnwrap(idx.root)
        let a = try items(idx)[0]
        idx = try XCTUnwrap(EditTransaction.moveArrayItem(in: root.id, fromIndex: 0, toIndex: 2,
                                                          in: idx)).applying(to: idx)

        XCTAssertEqual(idx.pathString(to: a.id), "root[2]")
        XCTAssertEqual(idx.resolvePath("root[2]"), a.id)
    }

    func testNestedArrayStepsUsePositionsToo() async throws {
        var idx = try await index(#"{"rows":[{"n":1},{"n":2}]}"#, ext: "json")
        let rowsKV = try items(idx)[0]
        let rows = try XCTUnwrap(idx.children(of: rowsKV.id).first)
        let firstRow = idx.children(of: rows.id)[0]
        idx = try XCTUnwrap(EditTransaction.removeNode(firstRow.id, in: idx)).applying(to: idx)

        let remaining = idx.children(of: rows.id)[0]
        let nKV = try XCTUnwrap(idx.children(of: remaining.id).first)
        XCTAssertEqual(idx.pathString(to: nKV.id), "root.rows[0].n")
        XCTAssertEqual(idx.resolvePath("root.rows[0].n"), nKV.id)
    }

    // MARK: - CSV rows have no key

    func testCSVCellPathIncludesItsRow() async throws {
        let idx = try await index("id,name\n1,Alice\n2,Bob\n", ext: "csv")
        let bobRow = try items(idx)[1]
        let nameKV = try XCTUnwrap(idx.children(of: bobRow.id).first { $0.key == "name" })

        XCTAssertEqual(idx.pathString(to: bobRow.id), "root[1]")
        XCTAssertEqual(idx.pathString(to: nameKV.id), "root[1].name")
        XCTAssertEqual(idx.resolvePath("root[1].name"), nameKV.id)
    }

    func testIndexOutOfRangeDoesNotResolve() async throws {
        let idx = try await index("id\n1\n", ext: "csv")
        XCTAssertNil(idx.resolvePath("root[1]"))
        XCTAssertNil(idx.resolvePath("root[-1]"))
    }
}
