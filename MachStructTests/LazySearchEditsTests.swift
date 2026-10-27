import XCTest
@testable import MachStructCore

/// The toolbar search in a large file builds the nodes that aren't loaded
/// from the file, but must see the document as edited: new values found,
/// old ones and deleted nodes gone, inserted nodes included (#63).
final class LazySearchEditsTests: XCTestCase {

    /// A large-file document with the root's keys and their values loaded,
    /// as the tree would show them.
    private func lazy(_ json: String) async throws -> (JSONSource, NodeIndex, MappedFile) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lazy-search-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        let file = try MappedFile(url: url)
        let source = try JSONSource(file: file)
        let root = try XCTUnwrap(source.node(for: source.rootID, parent: nil))
        var index = NodeIndex(root: root)
        var loaded = [NodeID: DocumentNode]()
        for id in root.childIDs {
            let kv = try XCTUnwrap(source.node(for: id, parent: root))
            loaded[id] = kv
            for valueID in kv.childIDs { loaded[valueID] = source.node(for: valueID, parent: kv) }
        }
        index.applySnapshot(loaded)
        return (source, index, file)
    }

    private func keyValue(_ index: NodeIndex, _ key: String) throws -> DocumentNode {
        let root = try XCTUnwrap(index.root)
        return try XCTUnwrap(index.children(of: root.id).first { $0.key == key })
    }

    private func search(_ q: String, _ index: NodeIndex, _ source: JSONSource,
                        _ file: MappedFile) -> [SearchMatch] {
        SearchEngine.search(query: q, in: index, source: source)
    }

    private let doc = #"{"a":"old","b":{"c":"deep"}}"#

    func testUnloadedNodesAreFoundFromTheFile() async throws {
        let (si, index, file) = try await lazy(doc)
        XCTAssertNil(index.nodesMatching { $0.key == "c" }.first, "c should not be loaded")

        let matches = search("deep", index, si, file)

        XCTAssertEqual(matches.map(\.matchedText), ["deep"])
        XCTAssertEqual(si.node(for: matches[0].rowNodeID, parent: nil)?.type, .keyValue)
    }

    func testAnEditedValueIsFoundByItsNewTextOnly() async throws {
        let (si, loaded, file) = try await lazy(doc)
        var index = loaded
        let a = try keyValue(index, "a")
        let value = try XCTUnwrap(index.children(of: a.id).first)
        index.updateNode(value.id) { $0.value = .scalar(.string("new")) }

        XCTAssertEqual(search("new", index, si, file).map(\.rowNodeID), [a.id])
        XCTAssertEqual(search("old", index, si, file).count, 0)
    }

    func testARenamedKeyIsFoundByItsNewName() async throws {
        let (si, loaded, file) = try await lazy(doc)
        var index = loaded
        let a = try keyValue(index, "a")
        index.updateNode(a.id) { $0.key = "renamed" }

        XCTAssertEqual(search("renamed", index, si, file).map(\.field), [.key])
        XCTAssertEqual(search("old", index, si, file).map(\.rowNodeID), [a.id])
    }

    func testADeletedSubtreeIsNotFoundEvenWhereItWasNeverLoaded() async throws {
        let (si, index, file) = try await lazy(doc)
        let b = try keyValue(index, "b")
        let edited = try XCTUnwrap(EditTransaction.removeNode(b.id, in: index)).applying(to: index)

        XCTAssertEqual(search("deep", edited, si, file).count, 0)
        XCTAssertEqual(search("b", edited, si, file).count, 0)
    }

    func testAnInsertedNodeIsFoundInDocumentOrder() async throws {
        let (si, index, file) = try await lazy(#"{"x":"m1","y":{"z":"m3"}}"#)
        let root = try XCTUnwrap(index.root)
        let tx = try XCTUnwrap(EditTransaction.insertKeyValue(key: "w", value: .string("m4"),
                                                              into: root.id, in: index))
        let edited = tx.applying(to: index)

        XCTAssertEqual(search("m", edited, si, file).map(\.matchedText), ["m1", "m3", "m4"])
    }
}
