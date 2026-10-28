import XCTest
import Yams
@testable import MachStructCore

/// A large YAML file's nodes come from `YAMLSource`'s compact records. Every
/// node must be the one composing the file and indexing it gives.
final class YAMLSourceTests: XCTestCase {

    private func mapped(_ yaml: String) throws -> MappedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaml-source-\(UUID().uuidString).yaml")
        try Data(yaml.utf8).write(to: url)
        return try MappedFile(url: url)
    }

    /// The node as compared: everything but IDs.
    private struct Shape: Equatable {
        let type: NodeType
        let depth: UInt16
        let key: String?
        let value: String
        let metadata: String
        let childCount: Int
    }

    private func shape(_ node: DocumentNode) -> Shape {
        Shape(type: node.type, depth: node.depth, key: node.key, value: "\(node.value)",
              metadata: node.metadata.map { "\($0)" } ?? "-", childCount: node.childIDs.count)
    }

    /// Walk `source` and `reference` together from their roots, comparing
    /// each node and its parent, path and children.
    private func assertMatches(_ source: YAMLSource, _ reference: StructuralIndex, _ label: String,
                               line: UInt = #line) {
        XCTAssertEqual(source.nodeCount, reference.nodeCount, label, line: line)
        XCTAssertEqual(source.looksTabular(), reference.looksTabular(), label, line: line)
        var stack: [(NodeID, NodeID, DocumentNode?, [NodeID])] = [(source.rootID, reference.rootID, nil, [])]
        var visited = 0
        while let (id, refID, parent, path) = stack.popLast() {
            visited += 1
            guard let node = source.node(for: id, parent: parent),
                  let ref = reference.node(for: refID, parent: nil) else {
                return XCTFail("\(label): missing node", line: line)
            }
            XCTAssertEqual(shape(node), shape(ref), label, line: line)
            XCTAssertEqual(node.parentID, parent?.id, label, line: line)
            XCTAssertEqual(source.path(to: id), path + [id], label, line: line)
            // Without a parent the node is the same, its depth found by walking up.
            XCTAssertEqual(source.node(for: id, parent: nil).map(shape), shape(node), label, line: line)
            XCTAssertEqual(source.node(for: id, parent: nil, internKeys: false)?.key, node.key, label, line: line)
            guard node.childIDs.count == ref.childIDs.count else { continue }
            for (child, refChild) in zip(node.childIDs, ref.childIDs).reversed() {
                stack.append((child, refChild, node, path + [id]))
            }
        }
        XCTAssertEqual(visited, reference.nodeCount, label, line: line)
    }

    private func reference(_ yaml: String) throws -> StructuralIndex {
        StructuralIndex(entries: try YAMLParser().indexEntries(composing: yaml))
    }

    private let samples = [
        "a: 1", "- x", "plain", "'quoted'", "\"dq\"", "   \n", "# comment only\n",
        """
        name: alice
        nothing: ~
        empty:
        bools: [true, no, ON]
        ints: [0, -1, 1_000, 0x1F, 0o17]
        floats: [1.5, .inf, .nan, 1e3]
        quoted: ['it''s', "tab\\there", "plain"]
        multi: this is
          folded plain
        """,
        """
        tagged:
          s: !!str 123
          i: !!int "42"
          custom: !thing value
          nonspecific: ! 12
          map: !custom {a: 1}
        block: |
          line one
          line two
        folded: >-
          folded
          text
        tagged_block: !!str |
          12
        """,
        """
        anchors:
          base: &base {a: 1, b: [x, y]}
          list: &items
            - &first one
            - two
        """,
        "flow: {a: [1, {b: c}], 'd e': \"f\\tg\", empty: {}, none: []}",
        "- - - deep\n    - x\n  - y\n- {}\n- []\n-\n- ''",
        "\"key with: colon\": v\n'single': w\n? plain explicit\n: z\n\"\": empty key\n\"esc\\tkey\": 1",
        "unicode: héllo ✓ 𝄞\n键: 值\nnul: \"a\\0b\"",
        "\u{FEFF}bom: true",
        "a: 1\n---\nb: 2\n",
        "---\n---\n...\n---\nx\n",
        "--- 1\n--- [a, b]\n--- {c: d}\n--- |\n  text\n",
        "--- &doc\nanchored: doc\n",
        "- {id: 1, name: a}\n- {id: 2, name: b}\n- {id: 3, name: c}",
        "- {id: 1, name: a}\n- {id: 2, other: b}",
    ]

    func testNodesMatchComposing() throws {
        for yaml in samples {
            let source = try XCTUnwrap(YAMLSource(file: try mapped(yaml)), yaml)
            assertMatches(source, try reference(yaml), yaml.debugDescription)
        }
    }

    func testRandomDocumentsMatchComposing() throws {
        var rng = SystemRandomNumberGenerator()
        let words: [String] = ["a", "x y", "", "~", "null", "Yes", "12", "0x1F", "1.5", ".NaN",
                               "with: colon", "#hash", "tab\there", "line\nbreak", "é", "'q'", "\"dq\"",
                               " lead", "trail ", "- dash", "[", "&a", "!t"]
        let styles: [Node.Scalar.Style] = [.plain, .singleQuoted, .doubleQuoted, .literal, .folded, .any]
        let tags: [Tag] = [.implicit, Tag(.str), Tag(.int), Tag(.bool), Tag("!custom")]
        var keyCounter = 0
        func node(_ depth: Int) -> Node {
            switch depth > 3 ? 0 : Int.random(in: 0..<3, using: &rng) {
            case 0:
                return .scalar(.init(words.randomElement(using: &rng)!, tags.randomElement(using: &rng)!,
                                     styles.randomElement(using: &rng)!))
            case 1:
                return .sequence(.init((0..<Int.random(in: 0...4, using: &rng)).map { _ in node(depth + 1) },
                                       .implicit, Bool.random(using: &rng) ? .flow : .block))
            default:
                let pairs: [(Node, Node)] = (0..<Int.random(in: 0...4, using: &rng)).map { _ in
                    keyCounter += 1
                    return (.scalar(.init("\(words.randomElement(using: &rng)!)\(keyCounter)", .implicit,
                                          styles.randomElement(using: &rng)!)), node(depth + 1))
                }
                return .mapping(.init(pairs, .implicit, Bool.random(using: &rng) ? .flow : .block))
            }
        }
        for _ in 0..<200 {
            let yaml = try Yams.serialize(nodes: (0..<Int.random(in: 1...3, using: &rng)).map { _ in node(0) })
            let source = try XCTUnwrap(YAMLSource(file: try mapped(yaml)), yaml)
            assertMatches(source, try reference(yaml), yaml.debugDescription)
        }
    }

    /// Text that is the file's bytes is read from the file; text that isn't
    /// is kept, and comes back exactly.
    func testTextIsReadFromTheFileOrKept() throws {
        let yaml = "plain: value\nsq: 'it''s'\ndq: \"a\\tb\"\nfolded: one\n  two\nblock: |\n  x\n"
        let source = try XCTUnwrap(YAMLSource(file: try mapped(yaml)))
        let full = source.completeNodeIndex(overlaying: NodeIndex(root: source.node(for: source.rootID, parent: nil)!))
        let values = full.nodesMatching { $0.type == .scalar }.map { "\($0.value)" }
        XCTAssertEqual(values, ["\(NodeValue.scalar(.string("value")))", "\(NodeValue.scalar(.string("it's")))",
                                "\(NodeValue.scalar(.string("a\tb")))", "\(NodeValue.scalar(.string("one two")))",
                                "\(NodeValue.scalar(.string("x\n")))"])
    }

    /// Editing, saving, exporting and querying a file through its source
    /// give what the whole document gives.
    func testEditsSaveExportAndQueryLikeTheWholeDocument() async throws {
        let yaml = "# people\nusers:\n" + (0..<50).map { "  - name: user\($0)   # n\n    age: \($0)\n" }.joined()
            + "meta: {owner: 'carol'}\n"
        let file = try mapped(yaml)
        let source = try XCTUnwrap(YAMLSource(file: file))
        let opened = NodeIndex(root: try XCTUnwrap(source.node(for: source.rootID, parent: nil)))
        let target = try XCTUnwrap(source.completeNodeIndex(overlaying: opened).nodesMatching {
            if case .scalar(.string("user42")) = $0.value { return true } else { return false }
        }.first?.id)
        var index = source.loading([target], subtrees: false, into: opened)
        index.updateNode(target) { $0.value = .scalar(.string("EDITED")) }
        let whole = source.completeNodeIndex(overlaying: index)

        let patched = YAMLSourcePatcher.patch(source: yaml, edited: index, documentSource: source)
        XCTAssertEqual(patched, yaml.replacingOccurrences(of: "user42 ", with: "EDITED "))
        XCTAssertEqual(try FormatConverter().convert(index: index, source: source, to: .json),
                       try FormatConverter().convert(index: whole, to: .json))

        let query = ".users[] | select(.age > 40) | .name"
        let lazy = try await QueryEngine().run(query, on: DocumentOverlay(index: index, source: source))
        let full = try await QueryEngine().run(query, on: whole)
        XCTAssertEqual(lazy.values, full.values)
        XCTAssertTrue(lazy.values.contains(.string("EDITED")))
    }

    func testFilesThatNeedComposingAreDeclined() throws {
        for yaml in ["a: &x 1\nb: *x", "a: 1\na: 2", "? [a]\n: b", "a: ["] {
            XCTAssertNil(YAMLSource(file: try mapped(yaml)), yaml)
        }
        XCTAssertNotNil(YAMLSource(file: try mapped("a: 1")))
    }

    func testForeignIDsAreNotNodes() throws {
        let source = try XCTUnwrap(YAMLSource(file: try mapped("a: 1")))
        let other = try XCTUnwrap(YAMLSource(file: try mapped("b: 2")))
        XCTAssertNil(source.node(for: other.rootID, parent: nil))
        XCTAssertEqual(source.path(to: other.rootID), [])
        // A file of one document doesn't use the record before its root.
        XCTAssertNil(source.node(for: NodeID(rawValue: source.rootID.rawValue - 1), parent: nil))
    }
}
