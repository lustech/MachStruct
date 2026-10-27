import XCTest
@testable import MachStructCore

/// `JSONSource` builds nodes from a large file's bytes (ADR-002). It must
/// describe the same tree as the eager parser, with IDs that stay the same.
final class JSONSourceTests: XCTestCase {

    private func file(_ json: String) throws -> MappedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("json-source-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return try MappedFile(url: url)
    }

    private func rootOnly(_ source: JSONSource) throws -> NodeIndex {
        NodeIndex(root: try XCTUnwrap(source.node(for: source.rootID, parent: nil)))
    }

    /// The tree as (depth, type, key, value) in document order.
    private func shape(_ index: NodeIndex) -> [String] {
        var out: [String] = []
        var stack: [(NodeID, Int)] = [(index.rootID, 0)]
        while let (id, depth) = stack.popLast() {
            guard let node = index.node(for: id) else { out.append("missing"); continue }
            let value: String
            switch node.value {
            case .scalar(let sv):          value = "\(sv)"
            case .container(let count):    value = "container(\(count))"
            default:                       value = ""
            }
            // Array elements carry their index as a key only on the eager path.
            let parentIsArray = node.parentID.flatMap { index.node(for: $0) }?.type == .array
            out.append("\(depth) \(node.type) \(parentIsArray ? "" : node.key ?? "") \(value)")
            for child in node.childIDs.reversed() { stack.append((child, depth + 1)) }
        }
        return out
    }

    private let documents = [
        #"{"a":1,"b":[true,false,null,{"c":"x"}],"d":{"e":{"f":[]}},"g":-1.5e3}"#,
        #"[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]"#,
        #"  [ 1 , "two" , [ 3 , [ ] ] , { } ]  "#,
        #"{"dup":1,"dup":2,"esc\"aped":"line\nbreak","é":"😀","big":12345678901234567890}"#,
        #""just a string""#,
        "42",
    ]

    func testBuildsTheSameTreeAsTheEagerParser() async throws {
        for json in documents {
            let f = try file(json)
            let source = try JSONSource(file: f)
            let lazy = source.completeNodeIndex(overlaying: try rootOnly(source))
            let eager = try await JSONParser().buildIndex(from: f).buildNodeIndex()
            XCTAssertEqual(shape(lazy), shape(eager), json)
            XCTAssertEqual(lazy.count, source.nodeCount, json)
        }
    }

    func testIDsAreTheSameEachTimeANodeIsBuilt() throws {
        let source = try JSONSource(file: file(documents[0]))
        let a = source.completeNodeIndex(overlaying: try rootOnly(source))
        let b = source.completeNodeIndex(overlaying: try rootOnly(source))
        XCTAssertEqual(Set(a.allNodeIDs), Set(b.allNodeIDs))
    }

    func testPathLeadsFromTheRootToEveryNode() throws {
        for json in documents {
            let source = try JSONSource(file: file(json))
            let index = source.completeNodeIndex(overlaying: try rootOnly(source))
            for id in index.allNodeIDs {
                var expected = [id]
                var parent = index.node(for: id)?.parentID
                while let p = parent {
                    expected.insert(p, at: 0)
                    parent = index.node(for: p)?.parentID
                }
                XCTAssertEqual(source.path(to: id), expected, json)
            }
        }
    }

    func testUnknownIDsAreNotNodes() throws {
        let source = try JSONSource(file: file("[1]"))
        let stranger = NodeID.generate()
        XCTAssertNil(source.node(for: stranger, parent: nil))
        XCTAssertEqual(source.path(to: stranger), [])
    }

    func testInvalidJSONThrowsWhereTheProblemIs() throws {
        XCTAssertThrowsError(try JSONSource(file: file("{\n  \"a\": 1,\n}"))) { error in
            let parseError = error as? ParseError
            XCTAssertEqual(parseError?.line, 3)
            XCTAssertEqual(parseError?.column, 1)
        }
    }

    func testLooksTabular() throws {
        XCTAssertTrue(try JSONSource(file: file(documents[1])).looksTabular())
        XCTAssertFalse(try JSONSource(file: file(#"[{"a":1},{"b":1}]"#)).looksTabular())
        XCTAssertFalse(try JSONSource(file: file(#"{"a":1}"#)).looksTabular())
    }

    func testEditsInTheIndexReplaceParsedNodes() throws {
        let source = try JSONSource(file: file(#"{"a":1,"b":2}"#))
        var index = try rootOnly(source)
        let root = try XCTUnwrap(index.root)
        let b = try XCTUnwrap(source.node(for: root.childIDs[1], parent: root))
        index.applySnapshot([b.id: b])
        index = try XCTUnwrap(EditTransaction.removeNode(b.id, in: index)).applying(to: index)

        let full = source.completeNodeIndex(overlaying: index)
        XCTAssertEqual(full.children(of: root.id).compactMap(\.key), ["a"])
    }

    func testFastScalarDecodingMatchesFoundation() throws {
        let tokens = ["0", "-0", "42", "-17", "9223372036854775807", "9223372036854775808",
                      "-9223372036854775809", "18446744073709551616", "1.0", "1.5", "-2.25e-3",
                      "1E2", "123456789012345678901234567890", "true", "false", "null",
                      #""""#, #""aé\n""#, #""plain""#]
        for token in tokens {
            let bytes = Array(token.utf8)
            let fast = bytes.withUnsafeBytes { JSONParser.decodeScalarBytes($0) }
            let any = try JSONSerialization.jsonObject(with: Data(bytes), options: .allowFragments)
            XCTAssertEqual(fast, ScalarValue(jsonAny: any), token)
        }
    }

    // MARK: - Saving

    func testSavingKeepsEditsAndCopiesEverythingElse() throws {
        let json = #"[{"n":1.50,"s":"a"},{"n":2},{"n":3e0,"deep":{"x":[1,2]}}]"#
        let f = try file(json)
        let source = try JSONSource(file: f)
        var index = try rootOnly(source)
        let root = try XCTUnwrap(index.root)

        // Load the first two rows, as the tree would, and edit them.
        let first = try XCTUnwrap(source.node(for: root.childIDs[0], parent: root))
        let second = try XCTUnwrap(source.node(for: root.childIDs[1], parent: root))
        let sKey = try XCTUnwrap(source.node(for: first.childIDs[1], parent: first))
        let sValue = try XCTUnwrap(source.node(for: sKey.childIDs[0], parent: sKey))
        index.applySnapshot([first.id: first, second.id: second, sKey.id: sKey, sValue.id: sValue])
        index.updateNode(sValue.id) { $0.value = .scalar(.string("edited")) }
        index = try XCTUnwrap(EditTransaction.removeNode(second.id, in: index)).applying(to: index)

        let out = try JSONDocumentSerializer(index: index, mappedFile: f, source: source)
            .serialize(pretty: false)

        XCTAssertEqual(String(decoding: out, as: UTF8.self),
                       #"[{"n":1.50,"s":"edited"},{"n":3e0,"deep":{"x":[1,2]}}]"# + "\n")
    }

    func testSavingAnUneditedDocumentCopiesIt() throws {
        let json = #"{"a" : [1, 2.50], "b":{ }}"#
        let f = try file(json)
        let source = try JSONSource(file: f)
        let out = try JSONDocumentSerializer(index: try rootOnly(source), mappedFile: f,
                                             source: source).serialize(pretty: false)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), #"{"a":[1, 2.50],"b":{ }}"# + "\n")
    }

    // MARK: - Search

    func testSearchingTheBytesFindsWhatSearchingTheNodesFinds() throws {
        let json = #"""
        {"Name":"Ålice","tags":["x\u0041y","KELVIN \u212A", "k"],"n":-0,"f":1E2,"g":2.50,
         "big":123456789012345678901,"t":true,"z":null,"nested":{"name":"Bob","Id":[10,-11]},
         "esc\"key":"tab\there","\u00c5ke":"é"}
        """#
        let source = try JSONSource(file: file(json))
        let shallow = try rootOnly(source)
        let full = source.completeNodeIndex(overlaying: shallow)
        let queries = ["name", "NAME", "ålice", "lice", "xay", "k", "kelvin", "-0", "0", "100",
                       "1e2", "2.5", "2.50", "12345678901234567890", "true", "nul", "1", "-1",
                       "bob", "id", "\"", "esc", "tab", "\t", "åke", "é", "Ke", "y"]
        for q in queries {
            let fast = SearchEngine.search(query: q, in: shallow, source: source)
            let nodes = SearchEngine.search(query: q, in: full)
            XCTAssertEqual(fast.map(\.rowNodeID), nodes.map(\.rowNodeID), q)
            XCTAssertEqual(fast.map(\.field), nodes.map(\.field), q)
            XCTAssertEqual(fast.map(\.matchedText), nodes.map(\.matchedText), q)
        }
    }
}
