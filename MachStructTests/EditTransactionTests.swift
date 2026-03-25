import XCTest
@testable import MachStructCore

// MARK: - EditTransactionTests

final class EditTransactionTests: XCTestCase {

    // MARK: - Fixture

    /// Builds a small document:
    ///   root (object)
    ///     kv "name"  → scalar "Alice"
    ///     kv "age"   → scalar 30
    ///     kv "tags"  → array
    ///                    scalar "swift"
    ///                    scalar "json"
    private func makeIndex() -> (index: NodeIndex,
                                  root: DocumentNode,
                                  nameKV: DocumentNode, nameScalar: DocumentNode,
                                  ageKV: DocumentNode,  ageScalar: DocumentNode,
                                  tagsKV: DocumentNode, tagsArr: DocumentNode,
                                  tag0: DocumentNode,   tag1: DocumentNode) {
        let root = DocumentNode(type: .object, value: .container(childCount: 3))
        var index = NodeIndex(root: root)

        func makeKV(_ key: String, depth: UInt16, parent: NodeID) -> DocumentNode {
            DocumentNode(id: .generate(), type: .keyValue, depth: depth,
                         parentID: parent, key: key, value: .unparsed)
        }
        func makeScalar(_ sv: ScalarValue, depth: UInt16, parent: NodeID) -> DocumentNode {
            DocumentNode(id: .generate(), type: .scalar, depth: depth,
                         parentID: parent, value: .scalar(sv))
        }

        let nameKV     = makeKV("name", depth: 1, parent: root.id)
        let nameScalar = makeScalar(.string("Alice"), depth: 2, parent: nameKV.id)
        let ageKV      = makeKV("age", depth: 1, parent: root.id)
        let ageScalar  = makeScalar(.integer(30), depth: 2, parent: ageKV.id)

        let tagsKV  = makeKV("tags", depth: 1, parent: root.id)
        let tagsArr = DocumentNode(id: .generate(), type: .array, depth: 2,
                                   parentID: tagsKV.id,
                                   childIDs: [],
                                   value: .container(childCount: 2))
        let tag0 = makeScalar(.string("swift"), depth: 3, parent: tagsArr.id)
        let tag1 = makeScalar(.string("json"),  depth: 3, parent: tagsArr.id)

        // Wire up the tree.
        index.insertChild(nameKV,     in: root.id,     at: 0)
        index.insertChild(nameScalar, in: nameKV.id,   at: 0)
        index.insertChild(ageKV,      in: root.id,     at: 1)
        index.insertChild(ageScalar,  in: ageKV.id,    at: 0)
        index.insertChild(tagsKV,     in: root.id,     at: 2)
        index.insert(tagsArr)
        index.updateNode(tagsKV.id) { $0.childIDs = [tagsArr.id] }
        index.insertChild(tag0, in: tagsArr.id, at: 0)
        index.insertChild(tag1, in: tagsArr.id, at: 1)

        return (index, root, nameKV, nameScalar, ageKV, ageScalar,
                tagsKV, tagsArr, tag0, tag1)
    }

    // MARK: - changeValue

    func testChangeValueApply() throws {
        let f = makeIndex()
        let tx = try XCTUnwrap(EditTransaction.changeValue(
            of: f.nameScalar.id, to: .scalar(.string("Bob")),
            description: "Change name", in: f.index))

        let updated = tx.applying(to: f.index)
        XCTAssertEqual(updated.node(for: f.nameScalar.id)?.value,
                       .scalar(.string("Bob")))
        // Other nodes unchanged.
        XCTAssertEqual(updated.node(for: f.ageScalar.id)?.value,
                       .scalar(.integer(30)))
    }

    func testChangeValueRevert() throws {
        let f = makeIndex()
        let tx = try XCTUnwrap(EditTransaction.changeValue(
            of: f.nameScalar.id, to: .scalar(.string("Bob")),
            description: "Change name", in: f.index))

        let updated  = tx.applying(to: f.index)
        let reverted = tx.reverting(from: updated)
        XCTAssertEqual(reverted.node(for: f.nameScalar.id)?.value,
                       .scalar(.string("Alice")))
    }

    func testChangeValueReturnsNilForUnknownID() {
        let f   = makeIndex()
        let bad = NodeID.generate()
        let tx  = EditTransaction.changeValue(of: bad, to: .scalar(.null),
                                               description: "", in: f.index)
        XCTAssertNil(tx)
    }

    // MARK: - renameKey

    func testRenameKeyApply() throws {
        let f  = makeIndex()
        let tx = try XCTUnwrap(EditTransaction.renameKey(
            of: f.nameKV.id, to: "fullName", in: f.index))

        let updated = tx.applying(to: f.index)
        XCTAssertEqual(updated.node(for: f.nameKV.id)?.key, "fullName")
    }

    func testRenameKeyRevert() throws {
        let f  = makeIndex()
        let tx = try XCTUnwrap(EditTransaction.renameKey(
            of: f.nameKV.id, to: "fullName", in: f.index))

        let updated  = tx.applying(to: f.index)
        let reverted = tx.reverting(from: updated)
        XCTAssertEqual(reverted.node(for: f.nameKV.id)?.key, "name")
    }

    func testRenameKeyFailsOnNonKeyValueNode() {
        let f  = makeIndex()
        let tx = EditTransaction.renameKey(of: f.nameScalar.id, to: "x", in: f.index)
        XCTAssertNil(tx)
    }

    // MARK: - insertKeyValue

    func testInsertKeyValueAddsNodes() throws {
        let f  = makeIndex()
        let tx = try XCTUnwrap(EditTransaction.insertKeyValue(
            key: "email", value: .string("alice@example.com"),
            into: f.root.id, in: f.index))

        let updated = tx.applying(to: f.index)
        // Root should have one more child.
        let rootChildren = updated.children(of: f.root.id)
        XCTAssertEqual(rootChildren.count, 4)
        // Find the new kv node.
        let newKV = rootChildren.first { $0.key == "email" }
        XCTAssertNotNil(newKV)
        // Its child scalar should have the right value.
        if let kv = newKV {
            let child = updated.children(of: kv.id).first
            XCTAssertEqual(child?.value, .scalar(.string("alice@example.com")))
        }
    }

    func testInsertKeyValueRevert() throws {
        let f  = makeIndex()
        let tx = try XCTUnwrap(EditTransaction.insertKeyValue(
            key: "email", value: .string("alice@example.com"),
            into: f.root.id, in: f.index))

        let updated  = tx.applying(to: f.index)
        let reverted = tx.reverting(from: updated)
        XCTAssertEqual(reverted.children(of: f.root.id).count, 3)
    }

    func testInsertKeyValueFailsOnArray() {
        let f  = makeIndex()
        let tx = EditTransaction.insertKeyValue(key: "x", value: .null,
                                                into: f.tagsArr.id, in: f.index)
        XCTAssertNil(tx)
    }

    // MARK: - insertArrayItem

    func testInsertArrayItemAddsNode() throws {
        let f  = makeIndex()
        let tx = try XCTUnwrap(EditTransaction.insertArrayItem(
            value: .string("objc"), into: f.tagsArr.id, in: f.index))

        let updated = tx.applying(to: f.index)
        XCTAssertEqual(updated.children(of: f.tagsArr.id).count, 3)
    }

    func testInsertArrayItemRevert() throws {
        let f  = makeIndex()
        let tx = try XCTUnwrap(EditTransaction.insertArrayItem(
            value: .string("objc"), into: f.tagsArr.id, in: f.index))

        let updated  = tx.applying(to: f.index)
        let reverted = tx.reverting(from: updated)
        XCTAssertEqual(reverted.children(of: f.tagsArr.id).count, 2)
    }

    // MARK: - removeNode

    func testRemoveScalarNode() throws {
        let f  = makeIndex()
        let tx = try XCTUnwrap(EditTransaction.removeNode(
            f.nameKV.id, in: f.index))

        let updated = tx.applying(to: f.index)
        XCTAssertNil(updated.node(for: f.nameKV.id))
        XCTAssertNil(updated.node(for: f.nameScalar.id))  // subtree removed
        XCTAssertEqual(updated.children(of: f.root.id).count, 2)
    }

    func testRemoveNodeRevert() throws {
        let f  = makeIndex()
        let tx = try XCTUnwrap(EditTransaction.removeNode(
            f.nameKV.id, in: f.index))

        let updated  = tx.applying(to: f.index)
        let reverted = tx.reverting(from: updated)
        XCTAssertNotNil(reverted.node(for: f.nameKV.id))
        XCTAssertNotNil(reverted.node(for: f.nameScalar.id))
        XCTAssertEqual(reverted.children(of: f.root.id).count, 3)
    }

    func testRemoveSubtreeRemovesAllDescendants() throws {
        let f  = makeIndex()
        let tx = try XCTUnwrap(EditTransaction.removeNode(
            f.tagsKV.id, in: f.index))

        let updated = tx.applying(to: f.index)
        XCTAssertNil(updated.node(for: f.tagsKV.id))
        XCTAssertNil(updated.node(for: f.tagsArr.id))
        XCTAssertNil(updated.node(for: f.tag0.id))
        XCTAssertNil(updated.node(for: f.tag1.id))
    }

    // MARK: - reversed

    func testReversedIsSymmetric() throws {
        let f  = makeIndex()
        let tx = try XCTUnwrap(EditTransaction.changeValue(
            of: f.ageScalar.id, to: .scalar(.integer(99)),
            description: "Age change", in: f.index))

        // applying reversed should produce the same result as reverting.
        let applied   = tx.applying(to: f.index)
        let reverted  = tx.reverting(from: applied)
        let reversed  = tx.reversed.applying(to: applied)
        XCTAssertEqual(reverted.node(for: f.ageScalar.id)?.value,
                       reversed.node(for: f.ageScalar.id)?.value)
    }

    // MARK: - NodeIndex.applySnapshot

    func testApplySnapshotUpdateExistingNode() {
        let f = makeIndex()
        var idx = f.index
        var updated = f.nameScalar
        updated.value = .scalar(.string("Charlie"))
        idx.applySnapshot([f.nameScalar.id: updated])
        XCTAssertEqual(idx.node(for: f.nameScalar.id)?.value,
                       .scalar(.string("Charlie")))
    }

    func testApplySnapshotDeletesNodes() {
        let f = makeIndex()
        var idx = f.index
        idx.applySnapshot([:], deletions: [f.tag0.id])
        XCTAssertNil(idx.node(for: f.tag0.id))
        XCTAssertNotNil(idx.node(for: f.tag1.id))
    }

    // MARK: - parseScalarValue helper

    func testParseScalarValueTypes() {
        XCTAssertEqual(parseScalarValue("null"),  .null)
        XCTAssertEqual(parseScalarValue("true"),  .boolean(true))
        XCTAssertEqual(parseScalarValue("false"), .boolean(false))
        XCTAssertEqual(parseScalarValue("42"),    .integer(42))
        XCTAssertEqual(parseScalarValue("-7"),    .integer(-7))
        XCTAssertEqual(parseScalarValue("3.14"),  .float(3.14))
        XCTAssertEqual(parseScalarValue("hello"), .string("hello"))
        XCTAssertEqual(parseScalarValue("\"hi\""), .string("hi"))   // strips quotes
    }
}
