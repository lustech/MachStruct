import XCTest
@testable import MachStructCore

/// `CSVSource` reads a large CSV file from its bytes (ADR-002). It must build
/// the tree `CSVParser` builds, whatever the file's quirks.
final class CSVSourceTests: XCTestCase {

    private func file(_ bytes: [UInt8]) throws -> MappedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("csv-source-\(UUID().uuidString).csv")
        try Data(bytes).write(to: url)
        return try MappedFile(url: url)
    }

    private func file(_ text: String) throws -> MappedFile { try file(Array(text.utf8)) }

    /// The tree as (depth, type, key, value, column) in document order.
    private func shape(_ index: NodeIndex) -> [String] {
        var out: [String] = []
        var stack: [(NodeID, Int)] = [(index.rootID, 0)]
        while let (id, depth) = stack.popLast() {
            guard let node = index.node(for: id) else { out.append("missing"); continue }
            var value = ""
            switch node.value {
            case .scalar(let sv):       value = "\(sv)"
            case .container(let count): value = "container(\(count))"
            default:                    break
            }
            var column = ""
            if case .csv(let meta)? = node.metadata {
                column = "\(meta.delimiter) \(meta.hasHeader) \(meta.columnIndex)"
            }
            out.append("\(depth) \(node.type) \(node.key ?? "-") \(value) \(column)")
            for child in node.childIDs.reversed() { stack.append((child, depth + 1)) }
        }
        return out
    }

    private func assertSameTree(_ f: MappedFile, _ label: String,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let source = CSVSource(file: f)
        let root = try XCTUnwrap(source.node(for: source.rootID, parent: nil))
        let lazy = source.completeNodeIndex(overlaying: NodeIndex(root: root))
        let eager = try await CSVParser().buildIndex(from: f).buildNodeIndex()
        XCTAssertEqual(shape(lazy), shape(eager), label, file: file, line: line)
        XCTAssertEqual(lazy.count, source.nodeCount, label, file: file, line: line)
    }

    func testBuildsTheSameTreeAsTheParser() async throws {
        let cases = [
            "id,name\n1,Alice\n2,Bob\n",
            "id,name\r\n1,Alice\r\n2,Bob",
            "id,name\r1,Alice\r2,Bob\r",
            "a,b\n\n1,2\n\n\n3,4\n",
            "name,quote\nx,\"he said \"\"hi\"\"\"\ny,\"line\nbreak\"\nz,\"a,b\"\n",
            "a,b,c\n1,2\n3,4,5,6,7\n",
            "a,column_3\n1,2,3\n",
            "1,2,3\n4,5,6\n",
            "x;y\n1;2\n3;4\n",
            "x\ty\n1\t2\n",
            "a,b\n1,\n,2\n,\n",
            "a,b\n\"\",x\n",
            "a,b\n\"1\",\"true\"\n\"null\",\" 7 \"\n",
            "a,b\n\"ab\"cd,e\n",
            "a,b\n1,\"unterminated\n",
            "only\n",
            "h1,h2\n",
            "é,ü\n😀,ñ\n",
        ]
        for text in cases {
            try await assertSameTree(try file(text), text)
        }
    }

    func testLatin1FilesAreDecodedAsLatin1() async throws {
        // "café,naïve\n1,2\n" in ISO-8859-1.
        let bytes: [UInt8] = [0x63, 0x61, 0x66, 0xE9, 0x2C, 0x6E, 0x61, 0xEF, 0x76, 0x65, 0x0A,
                              0x31, 0x2C, 0x32, 0x0A]
        try await assertSameTree(try file(bytes), "latin-1")
    }

    func testAByteOrderMarkIsKeptAsTheParserKeepsIt() async throws {
        try await assertSameTree(try file([0xEF, 0xBB, 0xBF] + Array("a,b\n1,2\n".utf8)), "bom")
    }

    func testPathLeadsFromTheRootToEveryNode() throws {
        for text in ["id,name\n1,Alice\n2,\"B,ob\"\n", "1,2\n3,4\n"] {
            let source = CSVSource(file: try file(text))
            let root = try XCTUnwrap(source.node(for: source.rootID, parent: nil))
            let index = source.completeNodeIndex(overlaying: NodeIndex(root: root))
            for id in index.allNodeIDs {
                var expected = [id]
                var parent = index.node(for: id)?.parentID
                while let p = parent {
                    expected.insert(p, at: 0)
                    parent = index.node(for: p)?.parentID
                }
                XCTAssertEqual(source.path(to: id), expected, text)
            }
        }
    }

    func testLooksTabular() throws {
        XCTAssertTrue(CSVSource(file: try file("a,b\n1,2\n3,4\n")).looksTabular())
        XCTAssertFalse(CSVSource(file: try file("1,2\n3,4\n")).looksTabular())
        XCTAssertFalse(CSVSource(file: try file("a,b\n1,2\n3\n")).looksTabular())
    }

    func testAgreesWithTheParserOnRandomText() async throws {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("ab1 ,;\"\"\n\n\r\t.-éE0+xpinf".unicodeScalars).map(String.init)
        let queryAlphabet = Array("ab1.e0-+xinf9".unicodeScalars).map(String.init)
        for _ in 0..<400 {
            let text = (0..<Int.random(in: 1...60, using: &rng))
                .map { _ in alphabet.randomElement(using: &rng)! }.joined()
            let f = try file("h1,h2\n" + text)
            try await assertSameTree(f, text.debugDescription)

            // And searching its bytes finds what searching its nodes finds.
            let source = CSVSource(file: f)
            let shallow = NodeIndex(root: try XCTUnwrap(source.node(for: source.rootID, parent: nil)))
            let full = source.completeNodeIndex(overlaying: shallow)
            for _ in 0..<5 {
                let q = (0..<Int.random(in: 1...3, using: &rng))
                    .map { _ in queryAlphabet.randomElement(using: &rng)! }.joined()
                XCTAssertEqual(SearchEngine.search(query: q, in: shallow, source: source).map(\.matchedText),
                               SearchEngine.search(query: q, in: full).map(\.matchedText),
                               "\(q) in \(text.debugDescription)")
            }
        }
    }

    // MARK: - Search

    func testSearchingTheBytesFindsWhatSearchingTheNodesFinds() throws {
        let csvs = [
            "id,Name,score,flag\n007,Alice,1e3,TRUE\n-7,\"Bob \"\"B\"\"\",inf,NULL\n+5,é,0x1p3,nan\n" +
            "12345678901234567890,  spaced  ,1.50,\"multi\nline\"\n",
            "1,2,3\n007,-0,inf\n",
        ]
        let queries = ["name", "NAME", "a", "7", "07", "-7", "5", "1000", "1000.0", "inf", "infinity",
                       "nan", "8.0", "true", "null", "b\"", "é", "spaced", "1.5", "e+", "9.223",
                       "line", "1", "0", "-0", "score"]
        for csv in csvs {
            let source = CSVSource(file: try file(csv))
            let shallow = NodeIndex(root: try XCTUnwrap(source.node(for: source.rootID, parent: nil)))
            let full = source.completeNodeIndex(overlaying: shallow)
            for q in queries {
                let fast = SearchEngine.search(query: q, in: shallow, source: source)
                let nodes = SearchEngine.search(query: q, in: full)
                XCTAssertEqual(fast.map(\.rowNodeID), nodes.map(\.rowNodeID), "\(q) in \(csv)")
                XCTAssertEqual(fast.map(\.field), nodes.map(\.field), "\(q) in \(csv)")
                XCTAssertEqual(fast.map(\.matchedText), nodes.map(\.matchedText), "\(q) in \(csv)")
            }
        }
    }

    func testSearchSeesEditedRows() throws {
        let source = CSVSource(file: try file("k,v\na,1\nb,2\nc,3\nd,4\n"))
        var index = NodeIndex(root: try XCTUnwrap(source.node(for: source.rootID, parent: nil)))
        let root = try XCTUnwrap(index.root)
        index.applySnapshot(source.build([root.id: root.childIDs], in: index))
        // Delete row b and insert a new row before c.
        index = try XCTUnwrap(EditTransaction.removeNode(root.childIDs[1], in: index)).applying(to: index)
        let row = DocumentNode(type: .object, depth: 1, parentID: root.id,
                               value: .container(childCount: 0))
        index.insertChild(row, in: root.id, at: 1)
        // Unload the rows again, as eviction would, keeping the edited root.
        index.evictNodes(Set(index.allNodeIDs).subtracting([root.id, row.id]))

        let full = source.completeNodeIndex(overlaying: index)
        for q in ["a", "b", "c", "d", "k", "1", "2"] {
            XCTAssertEqual(SearchEngine.search(query: q, in: index, source: source).map(\.rowNodeID),
                           SearchEngine.search(query: q, in: full).map(\.rowNodeID), q)
        }
        XCTAssertTrue(SearchEngine.search(query: "b", in: index, source: source).isEmpty)
    }
}
