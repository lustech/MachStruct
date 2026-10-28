import XCTest
@testable import MachStructCore

/// Column Stats and the Find & Replace match count in a large file walk the
/// document from its source instead of building every node (ADR-002 stage 3).
/// They must give what the whole document, edits included, would give.
final class LazyWholeDocumentScanTests: XCTestCase {

    private func mapped(_ text: String, ext: String) throws -> MappedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whole-scan-\(UUID().uuidString).\(ext)")
        try Data(text.utf8).write(to: url)
        return try MappedFile(url: url)
    }

    /// The source and an index holding only its root, as a large file opens.
    private func json(_ text: String) throws -> (any DocumentSource, NodeIndex) {
        let source = try JSONSource(file: try mapped(text, ext: "json"))
        return (source, NodeIndex(root: try XCTUnwrap(source.node(for: source.rootID, parent: nil))))
    }

    private func csv(_ text: String) throws -> (any DocumentSource, NodeIndex) {
        let source = CSVSource(file: try mapped(text, ext: "csv"))
        return (source, NodeIndex(root: try XCTUnwrap(source.node(for: source.rootID, parent: nil))))
    }

    /// `index` with the root's children and their children loaded.
    private func loadTwoLevels(_ index: NodeIndex, _ source: any DocumentSource) throws -> NodeIndex {
        var index = index
        let root = try XCTUnwrap(index.root)
        var loaded = [NodeID: DocumentNode]()
        for id in root.childIDs {
            let row = try XCTUnwrap(source.node(for: id, parent: root))
            loaded[id] = row
            for kvID in row.childIDs {
                let kv = try XCTUnwrap(source.node(for: kvID, parent: row))
                loaded[kvID] = kv
                for valueID in kv.childIDs { loaded[valueID] = source.node(for: valueID, parent: kv) }
            }
        }
        index.applySnapshot(loaded)
        return index
    }

    private let csvText = """
        name,age,score,active
        alice,30,1.5,true
        bob,,2.5,false
        carol,41,x,true
        alice,30,,

        """

    private let jsonText = #"""
        [{"name":"alice","age":30,"tags":["a","b"]},
         {"name":"bob","age":null,"extra":{"name":"inner"}},
         {"age":"forty","name":""},
         "loose",
         {"name":"dup","name":"second"}]
        """#

    private let patterns: [(String, SearchEngine.FindOptions)] = [
        ("alice", .init(useRegex: false, caseSensitive: false, scope: .both)),
        ("ALICE", .init(useRegex: false, caseSensitive: true, scope: .both)),
        ("name", .init(useRegex: false, caseSensitive: false, scope: .keys)),
        ("name", .init(useRegex: false, caseSensitive: false, scope: .values)),
        ("^[0-9]+$", .init(useRegex: true, caseSensitive: false, scope: .values)),
        ("a", .init(useRegex: false, caseSensitive: false, scope: .both)),
        ("(", .init(useRegex: true, caseSensitive: false, scope: .both)),
        ("", .init(useRegex: false, caseSensitive: false, scope: .both)),
    ]

    private func assertCountsMatch(_ index: NodeIndex, _ source: any DocumentSource,
                                   _ label: String, line: UInt = #line) {
        let full = source.completeNodeIndex(overlaying: index)
        for (pattern, options) in patterns {
            XCTAssertEqual(SearchEngine.matchCount(pattern: pattern, options: options,
                                                   in: index, source: source),
                           SearchEngine.matches(pattern: pattern, options: options, in: full).count,
                           "\(label): \(pattern) \(options.scope)", line: line)
        }
    }

    private func assertStatsMatch(_ index: NodeIndex, _ source: any DocumentSource,
                                  _ label: String, line: UInt = #line) {
        let full = source.completeNodeIndex(overlaying: index)
        XCTAssertEqual(ColumnStats.compute(in: index, source: source),
                       ColumnStats.compute(in: full), label, line: line)
    }

    // MARK: - Match count

    func testCountMatchesTheWholeDocumentForUnloadedFiles() throws {
        let (jsonSource, jsonIndex) = try json(jsonText)
        assertCountsMatch(jsonIndex, jsonSource, "json")
        let (csvSource, csvIndex) = try csv(csvText)
        assertCountsMatch(csvIndex, csvSource, "csv")
    }

    func testCountSeesEdits() throws {
        let (source, opened) = try csv(csvText)
        var index = try loadTwoLevels(opened, source)
        let root = try XCTUnwrap(index.root)
        let firstRow = try XCTUnwrap(index.children(of: root.id).first)
        let nameKV = try XCTUnwrap(index.children(of: firstRow.id).first)
        let name = try XCTUnwrap(index.children(of: nameKV.id).first)
        index.updateNode(name.id) { $0.value = .scalar(.string("zed")) }
        index.updateNode(nameKV.id) { $0.key = "renamed" }
        let lastRow = try XCTUnwrap(index.children(of: root.id).last)
        index = try XCTUnwrap(EditTransaction.removeNode(lastRow.id, in: index)).applying(to: index)

        assertCountsMatch(index, source, "edited csv")
        let options = SearchEngine.FindOptions(useRegex: false, caseSensitive: false, scope: .values)
        XCTAssertEqual(SearchEngine.matchCount(pattern: "alice", options: options,
                                               in: index, source: source), 0)
        XCTAssertEqual(SearchEngine.matchCount(pattern: "zed", options: options,
                                               in: index, source: source), 1)
    }

    /// Literal matching skips Foundation for printable-ASCII text; it must
    /// agree with Foundation everywhere.
    func testLiteralMatchingAgreesWithFoundation() {
        var rng = SystemRandomNumberGenerator()
        let alphabet: [String] = "aAbBzZ@[`{09 ~-.".map(String.init)
            + ["é", "K", "\u{212A}", "ß", "\r", "\n", "\r\n", "\t", "ﬀ"]
        func random(_ maxLength: Int) -> String {
            String((0 ..< Int.random(in: 0 ... maxLength, using: &rng))
                .map { _ in alphabet.randomElement(using: &rng)! }.joined())
        }
        for caseSensitive in [false, true] {
            let options = SearchEngine.FindOptions(useRegex: false, caseSensitive: caseSensitive,
                                                   scope: .both)
            for _ in 0 ..< 400 {
                let pattern = random(3)
                guard let matcher = TextMatcher(pattern: pattern, options: options) else {
                    XCTFail("no matcher for \(pattern.debugDescription)"); continue
                }
                for _ in 0 ..< 25 {
                    let text = random(8)
                    let expected = text.range(of: pattern,
                                              options: caseSensitive ? [] : [.caseInsensitive]) != nil
                    XCTAssertEqual(matcher.matches(text), expected,
                                   "\(pattern.debugDescription) in \(text.debugDescription), case \(caseSensitive)")
                }
            }
        }
    }

    // MARK: - Column Stats

    func testStatsMatchTheWholeDocumentForUnloadedFiles() throws {
        let (csvSource, csvIndex) = try csv(csvText)
        assertStatsMatch(csvIndex, csvSource, "csv")
        let (jsonSource, jsonIndex) = try json(jsonText)
        assertStatsMatch(jsonIndex, jsonSource, "json")
    }

    func testStatsReadTheExpectedValues() throws {
        let (source, index) = try csv(csvText)
        let stats = ColumnStats.compute(in: index, source: source)

        XCTAssertEqual(stats.map(\.id), ["name", "age", "score", "active"])
        XCTAssertEqual(stats.map(\.totalRows), [4, 4, 4, 4])
        XCTAssertEqual(stats[0].uniqueCount, 3)
        XCTAssertEqual(stats[1].emptyCount, 1)
        XCTAssertEqual(stats[1].detectedType, "Integer")
        XCTAssertEqual(stats[1].numMin, 30)
        XCTAssertEqual(stats[1].numMax, 41)
        XCTAssertEqual(stats[2].detectedType, "Mixed")
    }

    func testStatsSeeEdits() throws {
        let (source, opened) = try csv(csvText)
        var index = try loadTwoLevels(opened, source)
        let root = try XCTUnwrap(index.root)
        let secondRow = index.children(of: root.id)[1]
        let ageKV = index.children(of: secondRow.id)[1]
        let age = try XCTUnwrap(index.children(of: ageKV.id).first)
        index.updateNode(age.id) { $0.value = .scalar(.integer(99)) }
        let firstRow = try XCTUnwrap(index.children(of: root.id).first)
        index = try XCTUnwrap(EditTransaction.removeNode(firstRow.id, in: index)).applying(to: index)

        assertStatsMatch(index, source, "edited csv")
        let stats = ColumnStats.compute(in: index, source: source)
        XCTAssertEqual(stats[1].totalRows, 3)
        XCTAssertEqual(stats[1].numMax, 99)
        XCTAssertEqual(stats[1].emptyCount, 0)
    }

    func testStatsOfANonTabularRootAreEmpty() throws {
        let (source, index) = try json(#"{"a":1}"#)
        XCTAssertEqual(ColumnStats.compute(in: index, source: source), [])
        let (emptySource, emptyIndex) = try json("[]")
        XCTAssertEqual(ColumnStats.compute(in: emptyIndex, source: emptySource), [])
    }

    // MARK: - Reading cells from the bytes

    /// Random CSV files, with the cells whose displayed text isn't their
    /// bytes, counted and summarised from the bytes and from the whole
    /// document.
    func testRandomCSVsCountAndSummariseLikeTheWholeDocument() throws {
        var rng = SystemRandomNumberGenerator()
        let cells = ["alice", "Bob", "ALICE", "McBob", "", " padded ", "\"quoted, comma\"", "\"say \"\"hi\"\"\"",
                     "1e3", "1.50", "007", "-0", "42", "3.0", "inf", "-Infinity", "NaN", "nan",
                     "null", "NULL", "true", "TRUE", "False", "héllo", "\u{212A}elvin", "x\ty", "0x1F",
                     "\"multi\nline\"", "1_000", "+5", ".5", "5."]
        let names = ["name", "age", "name", "Ölm", "k"]
        let fragments = ["a", "al", "Bo", "AL", "cB", "Ice", "1", ".0", "e", "inf", "nul", "null", "tru", "TRUE", "nan", "Infinity",
                         "000", "5", "0x", "é", "k", "\u{212A}", "name", "ag", "quoted, ", "\"", " ", "multi\nl"]
        for round in 0..<60 {
            let columns = Int.random(in: 1...4, using: &rng)
            let header = Bool.random(using: &rng)
            var lines: [String] = []
            if header { lines.append((0..<columns).map { _ in names.randomElement(using: &rng)! }.joined(separator: ",")) }
            for _ in 0..<Int.random(in: 1...12, using: &rng) {
                let width = max(1, columns + Int.random(in: -1...1, using: &rng))
                lines.append((0..<width).map { _ in cells.randomElement(using: &rng)! }.joined(separator: ","))
                if Int.random(in: 0..<6, using: &rng) == 0 { lines.append("") }
            }
            let text = lines.joined(separator: "\n") + "\n"
            let (source, index) = try csv(text)
            let full = source.completeNodeIndex(overlaying: index)
            for _ in 0..<8 {
                let pattern = (0..<Int.random(in: 1...2, using: &rng)).map { _ in fragments.randomElement(using: &rng)! }.joined()
                let options = SearchEngine.FindOptions(useRegex: Int.random(in: 0..<5, using: &rng) == 0,
                                                       caseSensitive: Bool.random(using: &rng),
                                                       scope: [.keys, .values, .both].randomElement(using: &rng)!)
                XCTAssertEqual(SearchEngine.matchCount(pattern: pattern, options: options, in: index, source: source),
                               SearchEngine.matches(pattern: pattern, options: options, in: full).count,
                               "round \(round): \(pattern.debugDescription) \(options) in \(text.debugDescription)")
            }
            XCTAssertEqual(ColumnStats.compute(in: index, source: source), ColumnStats.compute(in: full),
                           "round \(round): \(text.debugDescription)")
        }
    }

    /// Unloaded rows are read from the bytes rather than built.
    func testUnloadedRowsAreScannedFromTheBytes() throws {
        let (source, index) = try csv(csvText)
        let rows = try XCTUnwrap(index.root).childIDs
        var visited: [(Int, String?, ScalarValue)] = []
        XCTAssertEqual(source.scanUnloaded(rows[...], skippingCellsWithout: [], visitingColumns: { _ in false }) {
            visited.append(($0, $1, $2))
        }, rows.count)
        XCTAssertEqual(visited.count, 16)
        XCTAssertEqual(visited[4].0, 1)
        XCTAssertEqual(visited[4].1, "name")
        XCTAssertEqual(visited[4].2, .string("bob"))
        XCTAssertEqual(visited[5].2, .string(""))

        // Cells that can't hold the needle are skipped, except in the
        // columns asked for.
        var skipped: [ScalarValue] = []
        _ = source.scanUnloaded(rows[...], skippingCellsWithout: Array("ali".utf8),
                                visitingColumns: { $0 == "active" }) { skipped.append($2) }
        XCTAssertEqual(skipped, [.string("alice"), .boolean(true), .boolean(false), .boolean(true),
                                 .string("alice"), .string("")])

        // Only rows of the root are scanned.
        let first = try XCTUnwrap(source.node(for: rows[0], parent: index.root))
        XCTAssertEqual(source.scanUnloaded(first.childIDs[...], skippingCellsWithout: [],
                                           visitingColumns: { _ in false }) { _, _, _ in }, 0)
    }
}
