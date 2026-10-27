import XCTest
@testable import MachStructCore

/// Regression tests for issue #23 — containers in files >= 5 MB expanded to
/// nothing.
///
/// Tree rows drill *through* `.keyValue` nodes: the row for `"events": [...]`
/// displays the children of the array, not the array itself. The lazy path
/// used to load only the keyValue's direct child (the array), which was
/// already loaded — so the grandchildren the row actually needed were never
/// built. Eviction made the same mistake about what a row needs.
final class LazyExpansionTests: XCTestCase {

    private let json = #"{"events":[{"id":1},{"id":2},{"id":3},{"id":4}],"meta":{"a":1,"b":2,"c":3,"d":4},"name":"x"}"#

    /// A large file's index as the tree first shows it: the root's keys and
    /// their values, nothing deeper.
    private func open(_ json: String) throws -> (JSONSource, NodeIndex) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lazyexp-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        let source = try JSONSource(file: MappedFile(url: url))
        var index = NodeIndex(root: try XCTUnwrap(source.node(for: source.rootID, parent: nil)))
        let root = try XCTUnwrap(index.root)
        index.applySnapshot(source.build([root.id: root.childIDs], in: index))
        return (source, index)
    }

    private func keyValue(_ key: String, in index: NodeIndex) throws -> DocumentNode {
        try XCTUnwrap(index.root.flatMap { index.children(of: $0.id).first { $0.key == key } })
    }

    // MARK: - What opening a row loads

    /// Opening a key whose value is an array loads the array's elements — the
    /// rows the user expects to see.
    func testOpeningAKeyLoadsItsValuesChildren() throws {
        let (_, index) = try open(json)
        let events = try keyValue("events", in: index)
        let array = try XCTUnwrap(index.children(of: events.id).first)

        let request = index.childrenToLoad(opening: [events.id], limit: 1_000)

        XCTAssertEqual(request, [array.id: array.childIDs])
        XCTAssertEqual(array.childIDs.count, 4)
    }

    func testOpeningAKeyWithAScalarValueLoadsNothing() throws {
        let (_, index) = try open(json)
        XCTAssertTrue(index.childrenToLoad(opening: [try keyValue("name", in: index).id],
                                           limit: 1_000).isEmpty)
    }

    func testContainersWithTooManyChildrenAreLeftToTheirRanges() throws {
        let (_, index) = try open(json)
        XCTAssertTrue(index.childrenToLoad(opening: [try keyValue("events", in: index).id],
                                           limit: 3).isEmpty)
    }

    func testOpeningUnknownIDsLoadsNothing() throws {
        let (_, index) = try open(json)
        XCTAssertTrue(index.childrenToLoad(opening: [NodeID.generate()], limit: 1_000).isEmpty)
    }

    /// End to end: after loading, every row the tree lists for the opened key
    /// resolves, and each key's row has the value it shows.
    func testLoadingMakesEveryListedRowResolvable() throws {
        let (source, loaded) = try open(json)
        var index = loaded
        let meta = try keyValue("meta", in: index)

        index.applySnapshot(source.build(index.childrenToLoad(opening: [meta.id], limit: 1_000),
                                         in: index))

        let object = try XCTUnwrap(index.listedContainer(for: meta.id))
        let rows = object.childIDs.compactMap { index.node(for: $0) }
        XCTAssertEqual(rows.compactMap(\.key), ["a", "b", "c", "d"])
        for row in rows {
            XCTAssertNotNil(row.childIDs.first.flatMap { index.node(for: $0) }, "value of \(row.key!)")
        }
    }

    // MARK: - What eviction keeps

    /// The rows under the root, with the value each key's row shows.
    func testRowsShownUnderTheRootIncludeTheirValues() throws {
        let (_, index) = try open(json)
        let root = try XCTUnwrap(index.root)

        let shown = index.rowsShown(expandedIDs: [], limit: 1_000)

        for id in root.childIDs {
            XCTAssertTrue(shown.contains(id))
            let kv = try XCTUnwrap(index.node(for: id))
            XCTAssertTrue(shown.contains(kv.childIDs[0]), "value of \(kv.key!)")
        }
    }

    /// An open key wrapping an array shows the array's elements.
    func testRowsShownUnderAnOpenKeyAreItsValuesChildren() throws {
        let (source, loaded) = try open(json)
        var index = loaded
        let events = try keyValue("events", in: index)
        index.applySnapshot(source.build(index.childrenToLoad(opening: [events.id], limit: 1_000),
                                         in: index))
        let array = try XCTUnwrap(index.listedContainer(for: events.id))

        let shown = index.rowsShown(expandedIDs: [events.id], limit: 1_000)

        XCTAssertTrue(Set(array.childIDs).isSubset(of: shown))
    }
}
