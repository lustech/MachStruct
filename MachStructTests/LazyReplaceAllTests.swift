import XCTest
@testable import MachStructCore

/// Replace All in a large file walks the document from its source and loads
/// only the edited nodes' ancestors (ADR-002 stage 3). Once committed, the
/// file must save as Replace All over the whole document would have left it.
final class LazyReplaceAllTests: XCTestCase {

    private func mapped(_ text: String, ext: String) throws -> MappedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lazy-replace-\(UUID().uuidString).\(ext)")
        try Data(text.utf8).write(to: url)
        return try MappedFile(url: url)
    }

    private struct Document {
        let source: any DocumentSource
        let file: MappedFile
        let isCSV: Bool
        var index: NodeIndex
    }

    /// A large file as it opens: only the root is in the index.
    private func open(_ text: String, csv: Bool) throws -> Document {
        let file = try mapped(text, ext: csv ? "csv" : "json")
        let source: any DocumentSource = csv ? CSVSource(file: file) : try JSONSource(file: file)
        let root = try XCTUnwrap(source.node(for: source.rootID, parent: nil))
        return Document(source: source, file: file, isCSV: csv, index: NodeIndex(root: root))
    }

    /// The file `index` would save as.
    private func saved(_ index: NodeIndex, _ doc: Document) throws -> String {
        let data = doc.isCSV
            ? try CSVDocumentSerializer(index: doc.source.completeNodeIndex(overlaying: index))
                .serializeInSourceLayout()
            : try JSONDocumentSerializer(index: index, mappedFile: doc.file, source: doc.source)
                .serialize(pretty: false)
        return String(decoding: data, as: UTF8.self)
    }

    private func commit(_ result: SearchEngine.LazyReplaceAll, to index: NodeIndex) -> NodeIndex {
        result.applying(to: index)
    }

    private let jsonText = #"""
        {"users":[{"name":"alice","age":30,"tags":["admin","a"]},
                  {"name":"bob","age":7,"extra":{"name":"inner","deep":[["alpha"]]}}],
         "name":"top","count":30}
        """#

    private let csvText = """
        name,age,city
        alice,30,Lund
        bob,7,Malmö
        carol,30,Lund

        """

    private let replacements: [(String, String, SearchEngine.FindOptions)] = [
        ("alice", "ALICE", .init(useRegex: false, caseSensitive: false, scope: .both)),
        ("name", "nm", .init(useRegex: false, caseSensitive: false, scope: .keys)),
        ("^30$", "31", .init(useRegex: true, caseSensitive: false, scope: .values)),
        ("a", "", .init(useRegex: false, caseSensitive: false, scope: .both)),
        ("l", "ll", .init(useRegex: false, caseSensitive: true, scope: .values)),
        ("Lund", "\"Lu,nd\"", .init(useRegex: false, caseSensitive: false, scope: .values)),
    ]

    private func assertSavesLikeTheWholeDocument(_ doc: Document, _ label: String,
                                                 line: UInt = #line) throws {
        let full = doc.source.completeNodeIndex(overlaying: doc.index)
        for (pattern, replacement, options) in replacements {
            let what = "\(label): \(pattern) → \(replacement)"
            let expected = SearchEngine.replaceAll(pattern: pattern, replacement: replacement,
                                                   options: options, in: full)
            let lazy = SearchEngine.replaceAll(pattern: pattern, replacement: replacement,
                                               options: options, in: doc.index, source: doc.source)
            XCTAssertEqual(lazy.map { Set($0.transaction.afterSnapshot.keys) },
                           expected.map { Set($0.afterSnapshot.keys) }, what, line: line)
            guard let lazy, let expected else { continue }

            let edited = commit(lazy, to: doc.index)
            XCTAssertEqual(try saved(edited, doc), try saved(expected.applying(to: full), doc),
                           what, line: line)
            XCTAssertEqual(try saved(lazy.transaction.reverting(from: edited), doc),
                           try saved(full, doc), "\(what), undone", line: line)
        }
    }

    func testSavesLikeTheWholeDocumentWhenNothingIsLoaded() throws {
        try assertSavesLikeTheWholeDocument(try open(jsonText, csv: false), "json")
        try assertSavesLikeTheWholeDocument(try open(csvText, csv: true), "csv")
    }

    func testSavesLikeTheWholeDocumentAfterEarlierEdits() throws {
        var doc = try open(jsonText, csv: false)
        let root = try XCTUnwrap(doc.index.root)
        var loaded = [NodeID: DocumentNode]()
        for id in root.childIDs {
            let kv = try XCTUnwrap(doc.source.node(for: id, parent: root))
            loaded[id] = kv
            for valueID in kv.childIDs { loaded[valueID] = doc.source.node(for: valueID, parent: kv) }
        }
        doc.index.applySnapshot(loaded)
        let top = try XCTUnwrap(doc.index.children(of: root.id).first { $0.key == "name" })
        let value = try XCTUnwrap(doc.index.children(of: top.id).first)
        doc.index.updateNode(value.id) { $0.value = .scalar(.string("alice again")) }

        try assertSavesLikeTheWholeDocument(doc, "edited json")
    }

    func testEveryAncestorIsRecordedAndOnlyMissingOnesLoaded() throws {
        let doc = try open(jsonText, csv: false)
        let options = SearchEngine.FindOptions(useRegex: false, caseSensitive: true, scope: .values)
        let result = try XCTUnwrap(SearchEngine.replaceAll(pattern: "alpha", replacement: "beta",
                                                           options: options, in: doc.index,
                                                           source: doc.source))
        // The root, users, its array, the second user, extra's kv and object,
        // deep's kv, and the two arrays.
        XCTAssertEqual(result.ancestors.count, 9)
        XCTAssertNotNil(result.ancestors[doc.index.rootID])
        XCTAssertEqual(result.transaction.afterSnapshot.count, 1)
        let edited = commit(result, to: doc.index)
        XCTAssertEqual(edited.count, 1 + 8 + 1)
        XCTAssertTrue(try saved(edited, doc).contains(#"[["beta"]]"#))
    }

    /// An ancestor loaded when the walk ran may be evicted before the edit is
    /// committed; committing must load it again or saving drops the edit.
    func testAnAncestorEvictedBeforeTheCommitIsLoadedAgain() throws {
        var doc = try open(jsonText, csv: false)
        let root = try XCTUnwrap(doc.index.root)
        let users = try XCTUnwrap(doc.source.node(for: root.childIDs[0], parent: root))
        let array = try XCTUnwrap(doc.source.node(for: users.childIDs[0], parent: users))
        doc.index.applySnapshot([users.id: users, array.id: array])
        let options = SearchEngine.FindOptions(useRegex: false, caseSensitive: true, scope: .values)
        let result = try XCTUnwrap(SearchEngine.replaceAll(pattern: "alpha", replacement: "beta",
                                                           options: options, in: doc.index,
                                                           source: doc.source))
        var evicted = doc.index
        // A missing container is saved as its original bytes; a key-value
        // pair isn't one, so evict the array.
        evicted.evictNodes([array.id])

        XCTAssertTrue(try saved(commit(result, to: evicted), doc).contains(#"[["beta"]]"#))
    }

    func testNothingToReplaceGivesNoEdit() throws {
        let doc = try open(csvText, csv: true)
        let options = SearchEngine.FindOptions(useRegex: false, caseSensitive: false, scope: .both)
        XCTAssertNil(SearchEngine.replaceAll(pattern: "zzz", replacement: "y", options: options,
                                             in: doc.index, source: doc.source))
        XCTAssertNil(SearchEngine.replaceAll(pattern: "", replacement: "y", options: options,
                                             in: doc.index, source: doc.source))
    }
}
