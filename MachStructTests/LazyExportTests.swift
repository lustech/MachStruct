import XCTest
@testable import MachStructCore

/// Large files keep only part of the tree in memory. Saving, exporting and
/// searching them must work from the whole document plus the edits made so
/// far — not from whatever happens to be materialised.
final class LazyExportTests: XCTestCase {

    private func write(_ text: String, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lazy-export-\(UUID().uuidString).\(ext)")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func csvIndex(_ csv: String) async throws -> (StructuralIndex, MappedFile) {
        let file = try MappedFile(url: write(csv, ext: "csv"))
        return (try await CSVParser().buildIndex(from: file), file)
    }

    private func rows(_ index: NodeIndex) throws -> [[String: Any]] {
        let data = try FormatConverter().convert(index: index, to: .json)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    /// The node holding `key` in the row at `row`.
    private func cell(_ index: NodeIndex, row: Int, key: String) throws -> DocumentNode {
        let rowNode = try XCTUnwrap(index.root.map { index.children(of: $0.id) }?[row])
        let kv = try XCTUnwrap(index.children(of: rowNode.id).first { $0.key == key })
        return try XCTUnwrap(index.children(of: kv.id).first)
    }

    func testOverlayMaterialisesRowsThatWereNeverExpanded() async throws {
        let (si, _) = try await csvIndex("id,name\n1,Alice\n2,Bob\n")

        let full = si.buildNodeIndex(overlaying: si.buildShallowNodeIndex())

        let out = try rows(full)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.last?["name"] as? String, "Bob")
    }

    func testOverlayKeepsEditedValues() async throws {
        let (si, _) = try await csvIndex("id,name\n1,Alice\n2,Bob\n")
        var current = si.buildNodeIndex()
        let bob = try cell(current, row: 1, key: "name")
        current.updateNode(bob.id) { $0.value = .scalar(.string("Robert")) }

        let out = try rows(si.buildNodeIndex(overlaying: current))

        XCTAssertEqual(out.map { $0["name"] as? String }, ["Alice", "Robert"])
    }

    func testOverlayKeepsDeletedRowsDeleted() async throws {
        let (si, _) = try await csvIndex("id,name\n1,Alice\n2,Bob\n")
        var current = si.buildNodeIndex()
        let firstRow = try XCTUnwrap(current.root.map { current.children(of: $0.id) }?.first)
        current.removeNode(firstRow.id)

        let out = try rows(si.buildNodeIndex(overlaying: current))

        XCTAssertEqual(out.map { $0["name"] as? String }, ["Bob"])
    }

    /// Search walks every stored node, so a deleted row must not linger as an
    /// unreachable orphan.
    func testOverlayDropsNodesNoLongerInTheTree() async throws {
        let (si, _) = try await csvIndex("id,name\n1,Alice\n2,Bob\n")
        var current = si.buildShallowNodeIndex()
        let firstRow = try XCTUnwrap(current.root.map { current.children(of: $0.id) }?.first)
        let alice = si.buildNodeIndex().children(of: firstRow.id).map(\.id)
        current.removeNode(firstRow.id)

        let full = si.buildNodeIndex(overlaying: current)

        XCTAssertNil(full.node(for: firstRow.id))
        XCTAssertTrue(alice.allSatisfy { full.node(for: $0) == nil })
    }

    func testOverlayKeepsInsertedNodes() async throws {
        let (si, _) = try await csvIndex("id,name\n1,Alice\n")
        var current = si.buildNodeIndex()
        let root = try XCTUnwrap(current.root)
        let row = DocumentNode(type: .object, depth: 1, parentID: root.id,
                               value: .container(childCount: 0))
        current.insertChild(row, in: root.id, at: 1)

        let out = try rows(si.buildNodeIndex(overlaying: current))

        XCTAssertEqual(out.count, 2)
    }

    func testLazyYAMLOverlayExportsEveryNode() async throws {
        let file = try MappedFile(url: write("people:\n  - name: Alice\n  - name: Bob\n", ext: "yaml"))
        let si = try await YAMLParser().buildIndex(from: file)

        let full = si.buildNodeIndex(overlaying: si.buildShallowNodeIndex())

        let data = try FormatConverter().convert(index: full, to: .json)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let people = try XCTUnwrap(json["people"] as? [[String: Any]])
        XCTAssertEqual(people.map { $0["name"] as? String }, ["Alice", "Bob"])
    }

    // MARK: - JSON save of a lazily loaded file

    private func lazyJSON(_ json: String) async throws -> (NodeIndex, MappedFile) {
        let file = try MappedFile(url: write(json, ext: "json"))
        return (try await JSONParser().buildIndex(from: file).buildShallowNodeIndex(), file)
    }

    private func saveJSON(_ index: NodeIndex, _ file: MappedFile) throws -> [String: Any] {
        let data = try JSONDocumentSerializer(index: index, mappedFile: file).serialize()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testDeletingAKeyFromALazyJSONFileSurvivesSave() async throws {
        let (index, file) = try await lazyJSON(#"{"a":1,"b":2}"#)
        let b = try XCTUnwrap(index.root.map { index.children(of: $0.id) }?.first { $0.key == "b" })
        let tx = try XCTUnwrap(EditTransaction.removeNode(b.id, in: index))

        let saved = try saveJSON(tx.applying(to: index), file)

        XCTAssertEqual(saved.keys.sorted(), ["a"])
    }
}
