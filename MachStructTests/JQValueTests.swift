import XCTest
@testable import MachStructCore

// MARK: - JQValue

/// Tests for the format-neutral value type the jq engine operates on, and its
/// bridges to/from the `DocumentNode` tree.
final class JQValueTests: XCTestCase {

    // MARK: Round-trip JQValue → DocumentNodes → JQValue

    func testRoundTripObject() {
        let value: JQValue = .object([
            ("name", .string("alice")),
            ("age", .int(30)),
            ("tags", .array([.string("a"), .string("b")])),
            ("active", .bool(true)),
            ("score", .double(3.5)),
            ("extra", .null),
        ])

        let built = value.toDocumentNodes(parentID: nil, depth: 0, key: nil)
        let index = NodeIndex(rootID: built.root, allNodes: built.nodes)
        let back = JQValue(node: built.root, in: index)

        XCTAssertEqual(back, value)
    }

    func testRoundTripNestedArray() {
        let value: JQValue = .array([
            .object([("id", .int(1))]),
            .object([("id", .int(2))]),
            .array([.int(3), .int(4)]),
        ])

        let built = value.toDocumentNodes(parentID: nil, depth: 0, key: nil)
        let index = NodeIndex(rootID: built.root, allNodes: built.nodes)
        let back = JQValue(node: built.root, in: index)

        XCTAssertEqual(back, value)
    }

    func testRoundTripScalar() {
        for value in [JQValue.int(7), .double(1.25), .string("hi"), .bool(false), .null] {
            let built = value.toDocumentNodes(parentID: nil, depth: 0, key: nil)
            let index = NodeIndex(rootID: built.root, allNodes: built.nodes)
            XCTAssertEqual(JQValue(node: built.root, in: index), value)
        }
    }

    // MARK: DocumentNode → JQValue (built from ScalarValue states)

    func testFromScalarValueNode() {
        let scalar = DocumentNode(type: .scalar, value: .scalar(.integer(42)))
        let index = NodeIndex(root: scalar)
        XCTAssertEqual(JQValue(node: scalar.id, in: index), .int(42))
    }

    func testUnparsedScalarBecomesNull() {
        // A scalar that was never materialised has no usable value in the
        // NodeIndex-only path; the bridge treats it as null rather than crashing.
        let scalar = DocumentNode(type: .scalar, value: .unparsed)
        let index = NodeIndex(root: scalar)
        XCTAssertEqual(JQValue(node: scalar.id, in: index), .null)
    }

    // MARK: Equality (manual conformance preserves object order)

    func testObjectEqualityIsOrderSensitive() {
        let a: JQValue = .object([("x", .int(1)), ("y", .int(2))])
        let b: JQValue = .object([("y", .int(2)), ("x", .int(1))])
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, .object([("x", .int(1)), ("y", .int(2))]))
    }

    // MARK: JSON serialisation (results pane copy/export)

    func testJSONStringCompact() {
        let v: JQValue = .object([("a", .int(1)), ("b", .array([.string("x"), .null]))])
        XCTAssertEqual(v.jsonString(pretty: false), "{\"a\":1,\"b\":[\"x\",null]}")
    }

    func testJSONStringEscapesStrings() {
        XCTAssertEqual(JQValue.string("he\"llo\n").jsonString(pretty: false), "\"he\\\"llo\\n\"")
    }

    func testJSONStringPrettyIndents() {
        let v: JQValue = .object([("a", .int(1))])
        XCTAssertEqual(v.jsonString(pretty: true), "{\n  \"a\": 1\n}")
    }

    func testJSONStringScalars() {
        XCTAssertEqual(JQValue.bool(true).jsonString(pretty: false), "true")
        XCTAssertEqual(JQValue.null.jsonString(pretty: false), "null")
        XCTAssertEqual(JQValue.int(-5).jsonString(pretty: false), "-5")
    }

    // MARK: Type name (used by the jq `type` builtin)

    func testTypeName() {
        XCTAssertEqual(JQValue.null.typeName, "null")
        XCTAssertEqual(JQValue.bool(true).typeName, "boolean")
        XCTAssertEqual(JQValue.int(1).typeName, "number")
        XCTAssertEqual(JQValue.double(1.5).typeName, "number")
        XCTAssertEqual(JQValue.string("s").typeName, "string")
        XCTAssertEqual(JQValue.array([]).typeName, "array")
        XCTAssertEqual(JQValue.object([]).typeName, "object")
    }
}
