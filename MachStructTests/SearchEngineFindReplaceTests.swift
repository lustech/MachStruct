import XCTest
@testable import MachStructCore

// MARK: - Find & Replace

final class SearchEngineFindReplaceTests: XCTestCase {

    private func index(from value: JQValue) -> NodeIndex {
        let built = value.toDocumentNodes(parentID: nil, depth: 0, key: nil)
        return NodeIndex(rootID: built.root, allNodes: built.nodes)
    }

    private func obj(_ pairs: [(String, JQValue)]) -> JQValue { .object(pairs.map { ($0.0, $0.1) }) }

    private var doc: JQValue {
        obj([("name", .string("alice")), ("nick", .string("ali")), ("age", .int(30))])
    }

    // MARK: Find

    func testFindLiteralInValues() {
        let idx = index(from: doc)
        let opts = SearchEngine.FindOptions(useRegex: false, caseSensitive: true, scope: .values)
        let matches = SearchEngine.matches(pattern: "ali", options: opts, in: idx)
        XCTAssertEqual(matches.count, 2)   // "alice" and "ali"
        XCTAssertTrue(matches.allSatisfy { $0.field == .value })
    }

    func testFindInKeys() {
        let idx = index(from: doc)
        let opts = SearchEngine.FindOptions(useRegex: false, caseSensitive: true, scope: .keys)
        let matches = SearchEngine.matches(pattern: "n", options: opts, in: idx)
        XCTAssertEqual(Set(matches.map { $0.originalText }), ["name", "nick"])
        XCTAssertTrue(matches.allSatisfy { $0.field == .key })
    }

    func testRegexMatch() {
        let idx = index(from: doc)
        let opts = SearchEngine.FindOptions(useRegex: true, caseSensitive: true, scope: .values)
        let matches = SearchEngine.matches(pattern: "^al.+e$", options: opts, in: idx)
        XCTAssertEqual(matches.map { $0.originalText }, ["alice"])
    }

    func testCaseInsensitiveFind() {
        let idx = index(from: doc)
        let opts = SearchEngine.FindOptions(useRegex: false, caseSensitive: false, scope: .values)
        let matches = SearchEngine.matches(pattern: "ALICE", options: opts, in: idx)
        XCTAssertEqual(matches.map { $0.originalText }, ["alice"])
    }

    // MARK: Replace

    func testReplaceAllInValues() {
        var idx = index(from: doc)
        let opts = SearchEngine.FindOptions(useRegex: false, caseSensitive: true, scope: .values)
        let tx = SearchEngine.replaceAll(pattern: "ali", replacement: "X",
                                         options: opts, in: idx)
        guard let tx else { return XCTFail("expected a transaction") }

        let nameID = idx.children(of: idx.rootID).first { $0.key == "name" }!.childIDs.first!
        let nickID = idx.children(of: idx.rootID).first { $0.key == "nick" }!.childIDs.first!

        idx = tx.applying(to: idx)
        XCTAssertEqual(JQValue(node: nameID, in: idx), .string("Xce"))
        XCTAssertEqual(JQValue(node: nickID, in: idx), .string("X"))

        // One undo step reverses the whole replacement.
        idx = tx.reverting(from: idx)
        XCTAssertEqual(JQValue(node: nameID, in: idx), .string("alice"))
        XCTAssertEqual(JQValue(node: nickID, in: idx), .string("ali"))
    }

    func testReplaceAllRenamesKeys() {
        var idx = index(from: doc)
        let opts = SearchEngine.FindOptions(useRegex: false, caseSensitive: true, scope: .keys)
        let tx = SearchEngine.replaceAll(pattern: "name", replacement: "label",
                                         options: opts, in: idx)
        guard let tx else { return XCTFail("expected a transaction") }
        idx = tx.applying(to: idx)
        XCTAssertNotNil(idx.children(of: idx.rootID).first { $0.key == "label" })
    }

    func testReplaceNoMatchReturnsNil() {
        let idx = index(from: doc)
        let opts = SearchEngine.FindOptions(useRegex: false, caseSensitive: true, scope: .both)
        XCTAssertNil(SearchEngine.replaceAll(pattern: "zzz", replacement: "q",
                                             options: opts, in: idx))
    }
}
