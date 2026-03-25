import XCTest
@testable import MachStructCore

// MARK: - JSONSerializerTests

final class JSONSerializerTests: XCTestCase {

    // MARK: - Fixture (same as EditTransactionTests)

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

    // MARK: - Full document serialization

    func testSerializeRoundTrip() throws {
        let f = makeIndex()
        let data = try JSONDocumentSerializer(index: f.index).serialize(pretty: false)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["name"] as? String, "Alice")
        XCTAssertEqual(json["age"] as? Int, 30)
        let tags = json["tags"] as? [Any]
        XCTAssertEqual(tags?.count, 2)
        XCTAssertEqual(tags?.first as? String, "swift")
        XCTAssertEqual(tags?.last  as? String, "json")
    }

    func testSerializeAppendsTrailingNewline() throws {
        let f    = makeIndex()
        let data = try JSONDocumentSerializer(index: f.index).serialize(pretty: true)
        XCTAssertTrue(data.last == UInt8(ascii: "\n"),
                      "Serialized output should end with newline")
    }

    func testSerializeEmptyDocumentThrows() {
        let empty = DocumentNode(type: .object, value: .container(childCount: 0))
        let emptyIndex = NodeIndex(root: empty)
        XCTAssertNoThrow(try JSONDocumentSerializer(index: emptyIndex).serialize())
    }

    // MARK: - Subtree serialization

    func testSerializeSubtreeScalar() throws {
        let f    = makeIndex()
        let data = try JSONDocumentSerializer(index: f.index)
            .serialize(nodeID: f.nameScalar.id, pretty: false)
        let str  = String(data: data, encoding: .utf8)
        XCTAssertEqual(str, "\"Alice\"")
    }

    func testSerializeSubtreeArray() throws {
        let f    = makeIndex()
        let data = try JSONDocumentSerializer(index: f.index)
            .serialize(nodeID: f.tagsArr.id, pretty: false)
        let arr  = try JSONSerialization.jsonObject(with: data) as! [String]
        XCTAssertEqual(arr, ["swift", "json"])
    }

    func testSerializeSubtreeKeyValueExposesValue() throws {
        let f    = makeIndex()
        // Serializing a keyValue node should expose the child value.
        let data = try JSONDocumentSerializer(index: f.index)
            .serialize(nodeID: f.nameKV.id, pretty: false)
        let str  = String(data: data, encoding: .utf8)
        XCTAssertEqual(str, "\"Alice\"")
    }

    func testSerializeNodeNotFoundThrows() {
        let f   = makeIndex()
        let bad = NodeID.generate()
        XCTAssertThrowsError(
            try JSONDocumentSerializer(index: f.index).serialize(nodeID: bad)
        )
    }

    // MARK: - Scalar types

    func testSerializeAllScalarTypes() throws {
        let root = DocumentNode(type: .object, value: .container(childCount: 5))
        var index = NodeIndex(root: root)
        let pairs: [(String, ScalarValue)] = [
            ("s",   .string("hello")),
            ("i",   .integer(-7)),
            ("f",   .float(3.14)),
            ("b",   .boolean(false)),
            ("n",   .null),
        ]
        for (i, (key, sv)) in pairs.enumerated() {
            let kv = DocumentNode(id: .generate(), type: .keyValue, depth: 1,
                                  parentID: root.id, key: key, value: .unparsed)
            let sc = DocumentNode(id: .generate(), type: .scalar, depth: 2,
                                  parentID: kv.id, value: .scalar(sv))
            var updKV = kv; updKV.childIDs = [sc.id]
            index.insertChild(updKV, in: root.id, at: i)
            index.insertChild(sc, in: kv.id, at: 0)
        }

        let data = try JSONDocumentSerializer(index: index).serialize(pretty: false)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["s"] as? String, "hello")
        XCTAssertEqual(json["i"] as? Int64,  -7)
        XCTAssertEqual((json["f"] as? Double) ?? 0, 3.14, accuracy: 1e-10)
        XCTAssertEqual(json["b"] as? Bool,   false)
        XCTAssertTrue(json["n"] is NSNull)
    }

    // MARK: - Unparsed nodes (no MappedFile)

    func testSerializeUnparsedWithoutFileFallsBackToNull() throws {
        let root    = DocumentNode(type: .object, value: .container(childCount: 1))
        var index   = NodeIndex(root: root)
        // Simulate a simdjson-path node with .unparsed value.
        let kv = DocumentNode(id: .generate(), type: .keyValue, depth: 1,
                               parentID: root.id, key: "x", value: .unparsed)
        let sc = DocumentNode(id: .generate(), type: .scalar, depth: 2,
                               parentID: kv.id, value: .unparsed,
                               sourceRange: .unknown)  // byteLength == 0 → no file read
        var updKV = kv; updKV.childIDs = [sc.id]
        index.insertChild(updKV, in: root.id, at: 0)
        index.insertChild(sc, in: kv.id, at: 0)

        let data = try JSONDocumentSerializer(index: index).serialize(pretty: false)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertTrue(json["x"] is NSNull, "Unparsed node without MappedFile should serialize as null")
    }
}

// MARK: - MoveArrayItemTests

final class MoveArrayItemTests: XCTestCase {

    private func makeArray(count: Int) -> (index: NodeIndex, parentID: NodeID, childIDs: [NodeID]) {
        let parent = DocumentNode(type: .array, value: .container(childCount: count))
        var index  = NodeIndex(root: parent)
        var ids    = [NodeID]()
        for i in 0..<count {
            let child = DocumentNode(id: .generate(), type: .scalar, depth: 1,
                                     parentID: parent.id, key: String(i),
                                     value: .scalar(.integer(Int64(i))))
            index.insertChild(child, in: parent.id, at: i)
            ids.append(child.id)
        }
        return (index, parent.id, ids)
    }

    func testMoveItemDown() throws {
        let f   = makeArray(count: 3)
        let tx  = try XCTUnwrap(EditTransaction.moveArrayItem(
            in: f.parentID, fromIndex: 0, toIndex: 1, in: f.index))
        let upd = tx.applying(to: f.index)
        let children = upd.children(of: f.parentID)
        XCTAssertEqual(children[0].id, f.childIDs[1])
        XCTAssertEqual(children[1].id, f.childIDs[0])
        XCTAssertEqual(children[2].id, f.childIDs[2])
    }

    func testMoveItemUp() throws {
        let f   = makeArray(count: 3)
        let tx  = try XCTUnwrap(EditTransaction.moveArrayItem(
            in: f.parentID, fromIndex: 2, toIndex: 1, in: f.index))
        let upd = tx.applying(to: f.index)
        let children = upd.children(of: f.parentID)
        XCTAssertEqual(children[0].id, f.childIDs[0])
        XCTAssertEqual(children[1].id, f.childIDs[2])
        XCTAssertEqual(children[2].id, f.childIDs[1])
    }

    func testMoveItemRevert() throws {
        let f   = makeArray(count: 3)
        let tx  = try XCTUnwrap(EditTransaction.moveArrayItem(
            in: f.parentID, fromIndex: 0, toIndex: 2, in: f.index))
        let updated  = tx.applying(to: f.index)
        let reverted = tx.reverting(from: updated)
        let children = reverted.children(of: f.parentID)
        XCTAssertEqual(children.map(\.id), f.childIDs)
    }

    func testMoveItemSameIndexReturnsNil() {
        let f  = makeArray(count: 3)
        let tx = EditTransaction.moveArrayItem(in: f.parentID, fromIndex: 1, toIndex: 1,
                                               in: f.index)
        XCTAssertNil(tx)
    }

    func testMoveItemOutOfBoundsReturnsNil() {
        let f  = makeArray(count: 3)
        let tx = EditTransaction.moveArrayItem(in: f.parentID, fromIndex: 0, toIndex: 5,
                                               in: f.index)
        XCTAssertNil(tx)
    }

    func testMoveItemOnNonArrayReturnsNil() {
        let root = DocumentNode(type: .object, value: .container(childCount: 0))
        let idx  = NodeIndex(root: root)
        let tx   = EditTransaction.moveArrayItem(in: root.id, fromIndex: 0, toIndex: 1,
                                                  in: idx)
        XCTAssertNil(tx)
    }
}

// MARK: - InsertFromClipboardTests

final class InsertFromClipboardTests: XCTestCase {

    // Object parent

    func testPasteScalarIntoObject() throws {
        let root = DocumentNode(type: .object, value: .container(childCount: 0))
        let index = NodeIndex(root: root)
        let json: Any = ["x": 42] as [String: Any]
        let tx = try XCTUnwrap(EditTransaction.insertFromClipboard(json, into: root.id,
                                                                    in: index))
        let updated = tx.applying(to: index)
        let kv = updated.children(of: root.id).first { $0.key == "x" }
        XCTAssertNotNil(kv)
        let scalar = updated.children(of: kv!.id).first
        XCTAssertEqual(scalar?.value, .scalar(.integer(42)))
    }

    func testPasteNonDictIntoObjectUsesKeyPasted() throws {
        let root  = DocumentNode(type: .object, value: .container(childCount: 0))
        let index = NodeIndex(root: root)
        let tx    = try XCTUnwrap(EditTransaction.insertFromClipboard("hello",
                                                                        into: root.id,
                                                                        in: index))
        let updated = tx.applying(to: index)
        let kv = updated.children(of: root.id).first { $0.key == "pasted" }
        XCTAssertNotNil(kv)
    }

    // Array parent

    func testPasteValueIntoArray() throws {
        let root  = DocumentNode(type: .array, value: .container(childCount: 0))
        let index = NodeIndex(root: root)
        let tx    = try XCTUnwrap(EditTransaction.insertFromClipboard("world",
                                                                        into: root.id,
                                                                        in: index))
        let updated = tx.applying(to: index)
        let children = updated.children(of: root.id)
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children.first?.value, .scalar(.string("world")))
    }

    func testPasteNestedObjectIntoArray() throws {
        let root  = DocumentNode(type: .array, value: .container(childCount: 0))
        let index = NodeIndex(root: root)
        let json: Any = ["name": "Alice", "age": 30] as [String: Any]
        let tx    = try XCTUnwrap(EditTransaction.insertFromClipboard(json,
                                                                        into: root.id,
                                                                        in: index))
        let updated  = tx.applying(to: index)
        let children = updated.children(of: root.id)
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children.first?.type, .object)
        let grandkids = updated.children(of: children.first!.id)
        XCTAssertEqual(grandkids.count, 2)  // "age" kv + "name" kv (sorted)
    }

    func testPasteRevert() throws {
        let root  = DocumentNode(type: .array, value: .container(childCount: 0))
        let index = NodeIndex(root: root)
        let tx    = try XCTUnwrap(EditTransaction.insertFromClipboard("item",
                                                                        into: root.id,
                                                                        in: index))
        let updated  = tx.applying(to: index)
        let reverted = tx.reverting(from: updated)
        XCTAssertEqual(reverted.children(of: root.id).count, 0)
    }

    func testPasteIntoScalarReturnsNil() {
        let root  = DocumentNode(type: .scalar, value: .scalar(.null))
        let index = NodeIndex(root: root)
        let tx    = EditTransaction.insertFromClipboard("x", into: root.id, in: index)
        XCTAssertNil(tx)
    }
}
