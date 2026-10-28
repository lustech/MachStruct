import XCTest
@testable import MachStructCore

/// Saving a large YAML file patches its text from the index and the source,
/// without building the whole document (ADR-002 stage 3): the result must be
/// what patching the whole document gives, and unloaded subtrees, which hold
/// no edits, are never built.
final class LazyYAMLSaveTests: XCTestCase {

    /// A source that counts the nodes built from it.
    private final class CountingSource: DocumentSource, @unchecked Sendable {
        let base: any DocumentSource
        private let lock = NSLock()
        private var built = 0

        init(_ base: any DocumentSource) { self.base = base }

        var count: Int { lock.withLock { built } }
        func reset() { lock.withLock { built = 0 } }

        var rootID: NodeID { base.rootID }
        var nodeCount: Int { base.nodeCount }
        func node(for id: NodeID, parent: DocumentNode?, internKeys: Bool) -> DocumentNode? {
            lock.withLock { built += 1 }
            return base.node(for: id, parent: parent, internKeys: internKeys)
        }
        func path(to id: NodeID) -> [NodeID] { base.path(to: id) }
        func looksTabular() -> Bool { base.looksTabular() }
    }

    private func source(_ yaml: String) async throws -> CountingSource {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lazy-yaml-\(UUID().uuidString).yaml")
        try Data(yaml.utf8).write(to: url)
        return CountingSource(try await YAMLParser().buildIndex(from: MappedFile(url: url)))
    }

    private func rootOnly(_ source: any DocumentSource) throws -> NodeIndex {
        NodeIndex(root: try XCTUnwrap(source.node(for: source.rootID, parent: nil)))
    }

    /// The scalar whose value is `value`, in the whole document.
    private func scalar(_ value: String, in full: NodeIndex) throws -> NodeID {
        try XCTUnwrap(full.nodesMatching {
            if case .scalar(.string(value)) = $0.value { return true } else { return false }
        }.first?.id, "no \(value)")
    }

    private let yaml = """
        # people
        users:
          - name: alice   # first
            tags: [a, b]
          - name: 'bob'
            tags: []
        meta:
          owner: "carol"
          count: 2
        """

    private let stream = """
        # one
        name: alice
        ---
        name: bob # two
        ---
        - x
        - y
        """

    func testUneditedFileSavesUnchangedWithoutBuildingNodes() async throws {
        for text in [yaml, stream] {
            let src = try await source(text)
            let opened = try rootOnly(src)
            src.reset()
            XCTAssertEqual(YAMLSourcePatcher.patch(source: text, edited: opened, documentSource: src), text)
            // The root's children are read to pair them with the source;
            // nothing below them is.
            XCTAssertEqual(src.count, try XCTUnwrap(opened.root).childIDs.count, text)
        }
    }

    func testEditsMatchPatchingTheWholeDocument() async throws {
        let cases: [(String, String, ScalarValue)] = [
            (yaml, "alice", .string("ALICE")),
            (yaml, "bob", .string("it's bob")),
            (yaml, "carol", .string("dave")),
            (yaml, "b", .string("bee")),
            (stream, "bob", .string("BOB")),
            (stream, "y", .string("why")),
        ]
        for (text, old, new) in cases {
            let src = try await source(text)
            let opened = try rootOnly(src)
            let id = try scalar(old, in: src.base.completeNodeIndex(overlaying: opened))
            var index = src.loading([id], subtrees: false, into: opened)
            index.updateNode(id) { $0.value = .scalar(new) }

            let expected = YAMLSourcePatcher.patch(source: text,
                                                   edited: src.base.completeNodeIndex(overlaying: index))
            XCTAssertNotNil(expected, old)
            src.reset()
            XCTAssertEqual(YAMLSourcePatcher.patch(source: text, edited: index, documentSource: src),
                           expected, old)
            XCTAssertLessThan(src.count, src.nodeCount, "\(old): built the whole document")
        }
    }

    func testAKeyRenameIsPatched() async throws {
        let src = try await source(yaml)
        let opened = try rootOnly(src)
        let full = src.base.completeNodeIndex(overlaying: opened)
        let owner = try XCTUnwrap(full.nodesMatching { $0.key == "owner" }.first?.id)
        var index = src.loading([owner], subtrees: false, into: opened)
        index.updateNode(owner) { $0.key = "lead" }

        let patched = try XCTUnwrap(YAMLSourcePatcher.patch(source: yaml, edited: index, documentSource: src))
        XCTAssertEqual(patched, yaml.replacingOccurrences(of: "owner:", with: "lead:"))
    }

    /// A structural edit can't be patched; the serializer writes the document
    /// from the index and the source.
    func testADeletionFallsBackToTheSerializer() async throws {
        let src = try await source(yaml)
        let opened = try rootOnly(src)
        let full = src.base.completeNodeIndex(overlaying: opened)
        let meta = try XCTUnwrap(full.nodesMatching { $0.key == "meta" }.first)
        var index = src.loading([meta.id], subtrees: true, into: opened)
        index.updateNode(index.rootID) { $0.childIDs.removeAll { $0 == meta.id } }

        XCTAssertNil(YAMLSourcePatcher.patch(source: yaml, edited: index, documentSource: src))
        let lazy = try YAMLDocumentSerializer(index: index, source: src).serialize()
        let whole = try YAMLDocumentSerializer(index: src.base.completeNodeIndex(overlaying: index)).serialize()
        XCTAssertEqual(lazy, whole)
        XCTAssertFalse(String(decoding: lazy, as: UTF8.self).contains("carol"))
    }
}
