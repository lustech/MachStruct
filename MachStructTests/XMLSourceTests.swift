import XCTest
@testable import MachStructCore

/// A large XML file's nodes come from `XMLSource`'s compact records. Every
/// node must be the one the SAX builder it replaced gave.
final class XMLSourceTests: XCTestCase {

    private func mapped(_ xml: String) throws -> MappedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xml-source-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: url)
        return try MappedFile(url: url)
    }

    /// The index the replaced SAX builder gave.
    private func reference(_ xml: String) throws -> StructuralIndex {
        let builder = ReferenceSAXBuilder()
        let parser = Foundation.XMLParser(data: Data(xml.utf8))
        parser.delegate = builder
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        guard parser.parse() else { throw XMLParserError.parseFailed }
        return StructuralIndex(entries: builder.indexEntries())
    }

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

    private func assertMatches(_ xml: String, line: UInt = #line) throws {
        let source = try XMLSource(file: try mapped(xml))
        let ref = try reference(xml)
        let label = xml.debugDescription
        XCTAssertEqual(source.nodeCount, ref.nodeCount, label, line: line)
        var stack: [(NodeID, NodeID, DocumentNode?, [NodeID])] = [(source.rootID, ref.rootID, nil, [])]
        var visited = 0
        while let (id, refID, parent, path) = stack.popLast() {
            visited += 1
            guard let node = source.node(for: id, parent: parent),
                  let refNode = ref.node(for: refID, parent: nil) else {
                return XCTFail("\(label): missing node", line: line)
            }
            XCTAssertEqual(shape(node), shape(refNode), label, line: line)
            XCTAssertEqual(node.metadata, refNode.metadata, label, line: line)
            XCTAssertEqual(node.parentID, parent?.id, label, line: line)
            XCTAssertEqual(source.path(to: id), path + [id], label, line: line)
            XCTAssertEqual(source.node(for: id, parent: nil).map(shape), shape(node), label, line: line)
            guard node.childIDs.count == refNode.childIDs.count else { continue }
            for (child, refChild) in zip(node.childIDs, refNode.childIDs).reversed() {
                stack.append((child, refChild, node, path + [id]))
            }
        }
        XCTAssertEqual(visited, ref.nodeCount, label, line: line)
        // The parser's entries are the same nodes.
        XCTAssertEqual(source.indexEntries().count, ref.entries.count, label, line: line)
    }

    private let samples = [
        "<a/>",
        "<a></a>",
        "<a>text</a>",
        "<a>  padded \n </a>",
        "<a>one<b/>two<c>three</c>  four  </a>",
        "<a x=\"1\" b=\"2\" a=\"3\"><b y='z'/></a>",
        "<r xmlns=\"urn:x\" xmlns:p=\"urn:p\"><p:item p:attr=\"v\">1</p:item><item>2</item></r>",
        "<a>Tom &amp; Jerry &lt;3 &#x2713; &#233;</a>",
        "<a><![CDATA[<raw> & stuff]]> and more</a>",
        "<?xml version=\"1.0\"?>\n<!-- c --><root><?pi data?><x>é ✓ 𝄞</x><!-- inner --></root>",
        "<a>\n  <b>\n    <c>deep</c>\n  </b>\n  <b/>\n</a>",
        "<a attr=\"&quot;q&quot; &amp; t\">x</a>",
        "<list><i>1</i><i>2</i><i>2</i><i/><i>  </i></list>",
    ]

    func testNodesMatchTheSAXBuilder() throws {
        for xml in samples { try assertMatches(xml) }
    }

    func testRandomDocumentsMatchTheSAXBuilder() throws {
        var rng = SystemRandomNumberGenerator()
        let names = ["a", "b", "item", "p:x", "y"]
        let texts = ["", "  ", "word", " two words ", "&amp;", "é", "<![CDATA[c&d]]>", "\n  x\n", "1.5", "&#x41;"]
        let attrs = ["", " id=\"1\"", " z=\"a\" a=\"z\"", " p:k=\"v\"", " v=\"&lt;&gt;\""]
        func element(_ depth: Int) -> String {
            let name = names.randomElement(using: &rng)!
            let attr = attrs.randomElement(using: &rng)!
            if depth > 3 || Int.random(in: 0..<4, using: &rng) == 0 { return "<\(name)\(attr)/>" }
            var body = ""
            for _ in 0..<Int.random(in: 0...4, using: &rng) {
                body += Bool.random(using: &rng) ? texts.randomElement(using: &rng)! : element(depth + 1)
            }
            return "<\(name)\(attr)>\(body)</\(name)>"
        }
        for _ in 0..<300 {
            try assertMatches("<root xmlns:p=\"urn:p\">\(element(0))</root>")
        }
    }

    func testMalformedFilesThrowTheParserError() throws {
        XCTAssertThrowsError(try XMLSource(file: try mapped("<a><b></a>"))) { error in
            let parseError = error as? ParseError
            XCTAssertNotNil(parseError?.line)
            XCTAssertTrue(parseError?.problem.contains("mismatch") == true, "\(error)")
        }
    }

    func testForeignIDsAreNotNodes() throws {
        let source = try XMLSource(file: try mapped("<a>1</a>"))
        let other = try XMLSource(file: try mapped("<b/>"))
        XCTAssertNil(source.node(for: other.rootID, parent: nil))
        XCTAssertEqual(source.path(to: other.rootID), [])
        XCTAssertNil(source.node(for: NodeID(rawValue: source.rootID.rawValue + 2), parent: nil))
    }

    /// Editing, saving as JSON and searching a large XML file through its
    /// source give what the whole document gives.
    func testEditsExportAndSearchLikeTheWholeDocument() throws {
        let xml = "<users>" + (0..<40).map { "<u id=\"\($0)\"><name>user\($0)</name><age>\($0)</age></u>" }.joined()
            + "</users>"
        let source = try XMLSource(file: try mapped(xml))
        let opened = NodeIndex(root: try XCTUnwrap(source.node(for: source.rootID, parent: nil)))
        let target = try XCTUnwrap(source.completeNodeIndex(overlaying: opened).nodesMatching {
            if case .scalar(.string("user17")) = $0.value { return true } else { return false }
        }.first?.id)
        var index = source.loading([target], subtrees: false, into: opened)
        index.updateNode(target) { $0.value = .scalar(.string("EDITED")) }
        let whole = source.completeNodeIndex(overlaying: index)

        XCTAssertEqual(try FormatConverter().convert(index: index, source: source, to: .json),
                       try FormatConverter().convert(index: whole, to: .json))
        let options = SearchEngine.FindOptions(useRegex: false, caseSensitive: false, scope: .both)
        XCTAssertEqual(SearchEngine.matchCount(pattern: "edited", options: options, in: index, source: source), 1)
        XCTAssertEqual(SearchEngine.matchCount(pattern: "user1", options: options, in: index, source: source),
                       SearchEngine.matches(pattern: "user1", options: options, in: whole).count)
    }
}
