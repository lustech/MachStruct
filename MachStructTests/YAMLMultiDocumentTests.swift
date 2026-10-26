import XCTest
@testable import MachStructCore

/// A YAML file can hold several documents separated by `---`. They open as a
/// list with one item per document, and save back as separate documents.
final class YAMLMultiDocumentTests: XCTestCase {

    private func write(_ yaml: String) throws -> MappedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("multidoc-\(UUID().uuidString).yaml")
        try Data(yaml.utf8).write(to: url)
        return try MappedFile(url: url)
    }

    private func index(_ yaml: String) async throws -> NodeIndex {
        try await YAMLParser().buildIndex(from: write(yaml)).buildNodeIndex()
    }

    private func isDocumentStream(_ node: DocumentNode?) -> Bool {
        guard case .yaml(let meta)? = node?.metadata else { return false }
        return meta.isDocumentStream
    }

    /// The value under `key` in the document at `doc`.
    private func value(_ index: NodeIndex, doc: Int, key: String) throws -> DocumentNode {
        let root = try XCTUnwrap(index.root)
        let document = index.children(of: root.id)[doc]
        let kv = try XCTUnwrap(index.children(of: document.id).first { $0.key == key })
        return try XCTUnwrap(index.children(of: kv.id).first)
    }

    private let twoDocs = "# first\nname: Alice\n---\n# second\nname: Bob\n"

    // MARK: - Opening

    func testEachDocumentBecomesAnItemOfTheRoot() async throws {
        let idx = try await index(twoDocs)

        let root = try XCTUnwrap(idx.root)
        XCTAssertEqual(root.type, .array)
        XCTAssertTrue(isDocumentStream(root))
        XCTAssertEqual(idx.children(of: root.id).map(\.type), [.object, .object])
        XCTAssertEqual(try value(idx, doc: 1, key: "name").value, .scalar(.string("Bob")))
    }

    func testASingleDocumentIsStillItsOwnRoot() async throws {
        let idx = try await index("---\nname: Alice\n...\n")

        let root = try XCTUnwrap(idx.root)
        XCTAssertEqual(root.type, .object)
        XCTAssertFalse(isDocumentStream(root))
    }

    func testDocumentsOfDifferentKindsAndEmptyOnesAreKept() async throws {
        let idx = try await index("---\n- 1\n- 2\n---\n---\nplain\n")

        let root = try XCTUnwrap(idx.root)
        let docs = idx.children(of: root.id)
        XCTAssertEqual(docs.map(\.type), [.array, .scalar, .scalar])
        XCTAssertEqual(docs[1].value, .scalar(.null))
        XCTAssertEqual(docs[2].value, .scalar(.string("plain")))
    }

    func testAnErrorInALaterDocumentNamesItsLine() async throws {
        do {
            _ = try await YAMLParser().buildIndex(from: write("a: 1\n---\nb: [1, 2\nc: 3\n"))
            XCTFail("expected a parse error")
        } catch let error as ParseError {
            XCTAssertEqual(error.line, 4)
        }
    }

    func testValidateAcceptsSeveralDocuments() async throws {
        let issues = try await YAMLParser().validate(file: write(twoDocs))
        XCTAssertTrue(issues.isEmpty, "\(issues.map(\.message))")
    }

    // MARK: - Saving

    func testSerializerWritesEachDocumentSeparately() async throws {
        let idx = try await index("a: 1\n---\n- x\n")

        let out = try String(decoding: YAMLDocumentSerializer(index: idx).serialize(), as: UTF8.self)

        XCTAssertEqual(out, "---\na: 1\n---\n- x\n")
    }

    func testPatcherEditsALaterDocumentInPlace() async throws {
        var idx = try await index(twoDocs)
        let bob = try value(idx, doc: 1, key: "name")
        idx.updateNode(bob.id) { $0.value = .scalar(.string("Robert")) }

        XCTAssertEqual(YAMLSourcePatcher.patch(source: twoDocs, edited: idx),
                       "# first\nname: Alice\n---\n# second\nname: Robert\n")
    }

    func testPatcherGivesUpWhenADocumentIsRemoved() async throws {
        var idx = try await index(twoDocs)
        let root = try XCTUnwrap(idx.root)
        idx.removeNode(idx.children(of: root.id)[0].id)

        XCTAssertNil(YAMLSourcePatcher.patch(source: twoDocs, edited: idx))
        let out = try String(decoding: YAMLDocumentSerializer(index: idx).serialize(), as: UTF8.self)
        XCTAssertEqual(out, "---\nname: Bob\n")
    }

    func testExportToJSONGivesAnArrayOfDocuments() async throws {
        let idx = try await index(twoDocs)

        let data = try FormatConverter().convert(index: idx, to: .json)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        XCTAssertEqual(json, [["name": "Alice"], ["name": "Bob"]])
    }
}
