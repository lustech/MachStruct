import XCTest
@testable import MachStructCore

/// Regression tests for issue #23 — containers in files >= 5 MB expanded to
/// nothing.
///
/// Tree rows drill *through* `.keyValue` nodes: the row for `"events": [...]`
/// displays the children of the array, not the array itself. The lazy
/// materialisation path materialised only the keyValue's direct child (the
/// array), which `buildShallowNodeIndex` had already placed in the index — so
/// its "is it already there?" probe always succeeded and the grandchildren the
/// row actually needed were never built.
final class LazyExpansionTests: XCTestCase {

    private func makeFile(json: String) throws -> MappedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lazyexp-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        return try MappedFile(url: url)
    }

    private func index(_ json: String) async throws -> (StructuralIndex, MappedFile) {
        let file = try makeFile(json: json)
        return (try await JSONParser().buildIndex(from: file), file)
    }

    /// Entry for the `.keyValue` node carrying `key`.
    private func keyValueEntry(_ si: StructuralIndex,
                               key: String,
                               file: MappedFile) -> IndexEntry? {
        si.entries.first { entry in
            guard entry.nodeType == .keyValue else { return false }
            if let k = entry.key { return k == key }
            guard entry.byteLength > 0,
                  let bytes = try? file.slice(offset: entry.byteOffset,
                                              length: entry.byteLength)
            else { return false }
            return JSONParser.decodeStringToken(bytes) == key
        }
    }

    // MARK: - The expansion contract

    /// Expanding a keyValue row whose value is an array must yield that array's
    /// elements — the rows the user expects to see.
    func testExpansionTargetsForKeyValueAreTheValuesChildren() async throws {
        let (si, file) = try await index(#"{"events":[{"a":1},{"a":2},{"a":3}],"n":7}"#)
        let kv = try XCTUnwrap(keyValueEntry(si, key: "events", file: file))

        let targets = si.expansionTargets(for: kv.id)
        XCTAssertEqual(targets.count, 3,
                       "expanding \"events\" should materialise the 3 array elements")

        // Every target must be an element of the array, not the array itself.
        let arrayID = try XCTUnwrap(si.childIndices[kv.id]?.first.map { si.entries[$0].id })
        for t in targets {
            XCTAssertEqual(si.entries[t].parentID, arrayID,
                           "target should be a child of the array")
            XCTAssertNotEqual(si.entries[t].id, arrayID,
                              "target must not be the array node itself")
        }
    }

    /// Same contract for an object value.
    func testExpansionTargetsForKeyValueWrappingObject() async throws {
        let (si, file) = try await index(#"{"summary":{"a":1,"b":2,"c":3,"d":4}}"#)
        let kv = try XCTUnwrap(keyValueEntry(si, key: "summary", file: file))
        XCTAssertEqual(si.expansionTargets(for: kv.id).count, 4,
                       "expanding \"summary\" should materialise its 4 keys")
    }

    /// A keyValue wrapping a scalar has no sub-rows, so nothing to materialise.
    func testExpansionTargetsForScalarKeyValueIsEmpty() async throws {
        let (si, file) = try await index(#"{"n":7}"#)
        let kv = try XCTUnwrap(keyValueEntry(si, key: "n", file: file))
        XCTAssertTrue(si.expansionTargets(for: kv.id).isEmpty)
    }

    /// Containers that are not behind a keyValue expand to their own children.
    func testExpansionTargetsForContainerAreItsOwnChildren() async throws {
        let (si, _) = try await index(#"[{"a":1},{"a":2}]"#)
        let root = try XCTUnwrap(si.entries.first)
        XCTAssertEqual(root.nodeType, .array)
        XCTAssertEqual(si.expansionTargets(for: root.id).count, 2)
    }

    func testExpansionTargetsForUnknownIDIsEmpty() async throws {
        let (si, _) = try await index(#"{"a":1}"#)
        XCTAssertTrue(si.expansionTargets(for: NodeID(rawValue: 999_999_999)).isEmpty)
    }

    // MARK: - The actual bug

    /// The shallow index already contains the value node of every root-level
    /// keyValue. Probing *that* node to decide "already materialised?" always
    /// succeeded, so expansion bailed out. The probe must instead be a node the
    /// row actually needs — one of the expansion targets.
    func testShallowIndexLacksGrandchildrenThatExpansionMustSupply() async throws {
        let (si, file) = try await index(
            #"{"events":[{"a":1},{"a":2},{"a":3}],"other":{"x":1}}"#)
        let shallow = si.buildShallowNodeIndex()
        let kv = try XCTUnwrap(keyValueEntry(si, key: "events", file: file))

        // The array node itself IS present — this is what the old probe checked.
        let arrayID = try XCTUnwrap(si.childIndices[kv.id]?.first.map { si.entries[$0].id })
        XCTAssertNotNil(shallow.node(for: arrayID),
                        "shallow build materialises the value node")

        // Its children are NOT — these are what the row needs.
        let targets = si.expansionTargets(for: kv.id)
        XCTAssertFalse(targets.isEmpty)
        for t in targets {
            XCTAssertNil(shallow.node(for: si.entries[t].id),
                         "array elements must still need materialising")
        }
    }

    /// End-to-end: after materialising the expansion targets, every row the UI
    /// would render for that node is resolvable in the index.
    func testMaterialisingTargetsMakesRowsResolvable() async throws {
        let (si, file) = try await index(
            #"{"events":[{"a":1},{"a":2},{"a":3}],"n":7}"#)
        var idx = si.buildShallowNodeIndex()
        let kv = try XCTUnwrap(keyValueEntry(si, key: "events", file: file))

        let targets = si.expansionTargets(for: kv.id)
        var updates = [NodeID: DocumentNode]()
        for t in targets {
            let e = si.entries[t]
            updates[e.id] = DocumentNode(
                id: e.id, type: e.nodeType, depth: e.depth,
                parentID: e.parentID,
                childIDs: (si.childIndices[e.id] ?? []).map { si.entries[$0].id },
                key: e.key, value: e.parsedValue.map { NodeValue.scalar($0) } ?? .unparsed)
        }
        idx.applySnapshot(updates)

        let arrayID = try XCTUnwrap(si.childIndices[kv.id]?.first.map { si.entries[$0].id })
        let rendered = idx.children(of: arrayID)
        XCTAssertEqual(rendered.count, 3,
                       "the expanded row should now render all 3 elements")
    }

    // MARK: - Eviction hot set

    /// Eviction must keep the nodes a rendered row depends on. Those follow the
    /// same drill-through as expansion: the row's children, plus — for keyValue
    /// rows — the value node each needs to display its value.
    func testVisibleDescendantsIncludeRowsAndTheirValueNodes() async throws {
        let (si, _) = try await index(#"{"a":1,"b":{"c":2},"d":[3,4]}"#)
        let root = try XCTUnwrap(si.entries.first)

        let visible = si.visibleDescendantIDs(for: root.id)

        // Root's own keyValue rows are present. (Nested ones, like "c" inside
        // "b", are not rows of root — they appear only when "b" is expanded.)
        let kvIDs = si.entries
            .filter { $0.nodeType == .keyValue && $0.parentID == root.id }
            .map(\.id)
        XCTAssertEqual(kvIDs.count, 3)
        for kv in kvIDs {
            XCTAssertTrue(visible.contains(kv), "keyValue row must stay hot")
        }
        // And each keyValue's value node, so the row can render its value.
        for kv in kvIDs {
            let valueID = try XCTUnwrap(si.childIndices[kv]?.first.map { si.entries[$0].id })
            XCTAssertTrue(visible.contains(valueID),
                          "value node must stay hot or the row loses its value")
        }
    }

    /// For an expanded keyValue wrapping an array, the elements are what render.
    func testVisibleDescendantsOfKeyValueAreTheArrayElements() async throws {
        let (si, file) = try await index(#"{"events":[{"a":1},{"a":2},{"a":3}]}"#)
        let kv = try XCTUnwrap(keyValueEntry(si, key: "events", file: file))

        let visible = si.visibleDescendantIDs(for: kv.id)
        let arrayID = try XCTUnwrap(si.childIndices[kv.id]?.first.map { si.entries[$0].id })
        let elementIDs = (si.childIndices[arrayID] ?? []).map { si.entries[$0].id }

        XCTAssertEqual(elementIDs.count, 3)
        for e in elementIDs {
            XCTAssertTrue(visible.contains(e),
                          "array elements must stay hot after being materialised")
        }
    }

    func testVisibleDescendantsOfScalarKeyValueIsEmpty() async throws {
        let (si, file) = try await index(#"{"n":7}"#)
        let kv = try XCTUnwrap(keyValueEntry(si, key: "n", file: file))
        XCTAssertTrue(si.visibleDescendantIDs(for: kv.id).isEmpty)
    }

}
