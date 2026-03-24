import XCTest
@testable import MachStructCore

// MARK: - NodeID

final class NodeIDTests: XCTestCase {

    func testGenerateIsUnique() {
        let ids = (0..<100).map { _ in NodeID.generate() }
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testGenerateIsMonotonic() {
        let a = NodeID.generate()
        let b = NodeID.generate()
        XCTAssert(b.rawValue > a.rawValue)
    }

    func testHashable() {
        let id = NodeID.generate()
        var dict: [NodeID: String] = [:]
        dict[id] = "value"
        XCTAssertEqual(dict[id], "value")
    }

    func testIdentifiable() {
        let id = NodeID(rawValue: 42)
        XCTAssertEqual(id.id, 42)
    }
}

// MARK: - ScalarValue

final class ScalarValueTests: XCTestCase {

    func testDisplayText() {
        XCTAssertEqual(ScalarValue.string("hello").displayText, "\"hello\"")
        XCTAssertEqual(ScalarValue.integer(42).displayText, "42")
        XCTAssertEqual(ScalarValue.integer(-1).displayText, "-1")
        XCTAssertEqual(ScalarValue.float(3.14).displayText, "3.14")
        XCTAssertEqual(ScalarValue.float(1.0).displayText, "1.0")
        XCTAssertEqual(ScalarValue.boolean(true).displayText, "true")
        XCTAssertEqual(ScalarValue.boolean(false).displayText, "false")
        XCTAssertEqual(ScalarValue.null.displayText, "null")
    }

    func testTypeBadge() {
        XCTAssertEqual(ScalarValue.string("x").typeBadge, "str")
        XCTAssertEqual(ScalarValue.integer(1).typeBadge, "int")
        XCTAssertEqual(ScalarValue.float(1.5).typeBadge, "num")
        XCTAssertEqual(ScalarValue.boolean(true).typeBadge, "bool")
        XCTAssertEqual(ScalarValue.null.typeBadge, "null")
    }

    func testEquality() {
        XCTAssertEqual(ScalarValue.string("a"), ScalarValue.string("a"))
        XCTAssertNotEqual(ScalarValue.string("a"), ScalarValue.string("b"))
        XCTAssertEqual(ScalarValue.integer(0), ScalarValue.integer(0))
        XCTAssertEqual(ScalarValue.null, ScalarValue.null)
    }
}

// MARK: - DocumentNode

final class DocumentNodeTests: XCTestCase {

    func testDefaultsAfterInit() {
        let node = DocumentNode(type: .object)
        XCTAssertEqual(node.type, .object)
        XCTAssertEqual(node.depth, 0)
        XCTAssertNil(node.parentID)
        XCTAssertTrue(node.childIDs.isEmpty)
        XCTAssertNil(node.key)
        XCTAssertEqual(node.value, .unparsed)
        XCTAssertEqual(node.sourceRange, .unknown)
        XCTAssertNil(node.metadata)
    }

    func testCustomID() {
        let id = NodeID(rawValue: 999)
        let node = DocumentNode(id: id, type: .scalar)
        XCTAssertEqual(node.id, id)
    }
}

// MARK: - NodeIndex helpers

extension NodeIndexTests {
    // Returns (index, root, kvNode, scalarNode) representing:
    //   root (object) → kv (.keyValue, key:"name") → scalar (.scalar, "Alice")
    func makeTree() -> (NodeIndex, DocumentNode, DocumentNode, DocumentNode) {
        let rootID  = NodeID.generate()
        let kvID    = NodeID.generate()
        let scalarID = NodeID.generate()

        var root   = DocumentNode(id: rootID,   type: .object,   depth: 0)
        var kv     = DocumentNode(id: kvID,     type: .keyValue, depth: 1,
                                  parentID: rootID, key: "name")
        let scalar = DocumentNode(id: scalarID, type: .scalar,   depth: 2,
                                  parentID: kvID,
                                  value: .scalar(.string("Alice")))

        root.childIDs = [kvID]
        kv.childIDs   = [scalarID]

        var index = NodeIndex(root: root)
        index.insert(kv)
        index.insert(scalar)

        return (index, root, kv, scalar)
    }
}

// MARK: - NodeIndex

final class NodeIndexTests: XCTestCase {

    // MARK: Basic queries

    func testNodeLookup() {
        let (index, root, kv, scalar) = makeTree()
        XCTAssertEqual(index.node(for: root.id)?.id,   root.id)
        XCTAssertEqual(index.node(for: kv.id)?.id,     kv.id)
        XCTAssertEqual(index.node(for: scalar.id)?.id, scalar.id)
        XCTAssertNil(index.node(for: NodeID(rawValue: 0)))
    }

    func testRootAccessor() {
        let (index, root, _, _) = makeTree()
        XCTAssertEqual(index.root?.id, root.id)
    }

    func testCount() {
        let (index, _, _, _) = makeTree()
        XCTAssertEqual(index.count, 3)
    }

    func testChildren() {
        let (index, root, kv, scalar) = makeTree()

        let rootChildren = index.children(of: root.id)
        XCTAssertEqual(rootChildren.count, 1)
        XCTAssertEqual(rootChildren.first?.id, kv.id)

        let kvChildren = index.children(of: kv.id)
        XCTAssertEqual(kvChildren.count, 1)
        XCTAssertEqual(kvChildren.first?.id, scalar.id)

        XCTAssertTrue(index.children(of: scalar.id).isEmpty)
    }

    func testParent() {
        let (index, root, kv, scalar) = makeTree()
        XCTAssertNil(index.parent(of: root.id))
        XCTAssertEqual(index.parent(of: kv.id)?.id,     root.id)
        XCTAssertEqual(index.parent(of: scalar.id)?.id, kv.id)
    }

    func testPath() {
        let (index, root, kv, scalar) = makeTree()
        let path = index.path(to: scalar.id)
        XCTAssertEqual(path, [root.id, kv.id, scalar.id])
    }

    func testPathStringForObject() {
        let (index, _, _, scalar) = makeTree()
        // root → .name → (scalar has no key, skipped) → "root.name"
        // kv node has key "name", parent is object → ".name"
        XCTAssertEqual(index.pathString(to: scalar.id), "root.name")
    }

    func testPathStringForArrayElement() {
        // Build: root (array) → element (object, key: "0")
        let rootID = NodeID.generate()
        let elemID = NodeID.generate()
        var root = DocumentNode(id: rootID, type: .array,  depth: 0)
        let elem = DocumentNode(id: elemID, type: .object, depth: 1,
                                parentID: rootID, key: "0")
        root.childIDs = [elemID]

        var index = NodeIndex(root: root)
        index.insert(elem)

        XCTAssertEqual(index.pathString(to: elemID), "root[0]")
    }

    // MARK: Search

    func testNodesMatching() {
        let (index, _, _, _) = makeTree()
        let scalars = index.nodesMatching { $0.type == .scalar }
        XCTAssertEqual(scalars.count, 1)
        XCTAssertEqual(scalars.first?.value, .scalar(.string("Alice")))
    }

    func testNodesAtDepth() {
        let (index, _, _, _) = makeTree()
        XCTAssertEqual(index.nodesAtDepth(0).count, 1)
        XCTAssertEqual(index.nodesAtDepth(1).count, 1)
        XCTAssertEqual(index.nodesAtDepth(2).count, 1)
        XCTAssertEqual(index.nodesAtDepth(3).count, 0)
    }

    // MARK: Mutation

    func testUpdateNode() {
        var (index, root, _, _) = makeTree()
        index.updateNode(root.id) { $0.key = "updated" }
        XCTAssertEqual(index.node(for: root.id)?.key, "updated")
    }

    func testUpdateNodeNoOp() {
        var (index, _, _, _) = makeTree()
        let countBefore = index.count
        index.updateNode(NodeID(rawValue: 9999)) { $0.key = "ghost" }
        XCTAssertEqual(index.count, countBefore)
    }

    func testInsertChild() {
        var (index, root, _, _) = makeTree()
        let age = DocumentNode(id: NodeID.generate(), type: .keyValue,
                               depth: 1, parentID: root.id, key: "age")
        index.insertChild(age, in: root.id, at: 1)

        let children = index.children(of: root.id)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[1].key, "age")
        XCTAssertEqual(index.count, 4)
    }

    func testRemoveNode() {
        var (index, root, kv, scalar) = makeTree()
        index.removeNode(kv.id)

        XCTAssertNil(index.node(for: kv.id))
        XCTAssertNil(index.node(for: scalar.id))      // entire subtree removed
        XCTAssertTrue(index.children(of: root.id).isEmpty) // parent updated
        XCTAssertEqual(index.count, 1)
    }

    // MARK: COW semantics

    func testCOWMutationDoesNotAffectOriginal() {
        let (original, root, _, _) = makeTree()
        var copy = original

        copy.updateNode(root.id) { $0.key = "mutated" }

        XCTAssertNil(original.node(for: root.id)?.key, "original must be unchanged")
        XCTAssertEqual(copy.node(for: root.id)?.key, "mutated")
    }

    func testCOWInsertDoesNotAffectOriginal() {
        let (original, root, _, _) = makeTree()
        var copy = original

        let extra = DocumentNode(id: NodeID.generate(), type: .keyValue,
                                 depth: 1, parentID: root.id, key: "extra")
        copy.insertChild(extra, in: root.id, at: 0)

        XCTAssertEqual(original.count, 3)
        XCTAssertEqual(copy.count, 4)
    }

    // MARK: Sendable — use across actor boundary

    func testSendableAcrossActorBoundary() async {
        let (index, _, _, scalar) = makeTree()
        let expected = NodeValue.scalar(.string("Alice"))

        let result = await Task.detached {
            index.node(for: scalar.id)?.value
        }.value

        XCTAssertEqual(result, expected)
    }
}
