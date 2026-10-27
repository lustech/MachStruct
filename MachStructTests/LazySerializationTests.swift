import XCTest
@testable import MachStructCore

/// Saving and exporting a large file serialize from its index and source,
/// building what the index lacks as they write instead of building the whole
/// document first (ADR-002 stage 3). The output must be what serializing the
/// whole document gives.
final class LazySerializationTests: XCTestCase {

    private func mapped(_ text: String, ext: String) throws -> MappedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lazy-serialize-\(UUID().uuidString).\(ext)")
        try Data(text.utf8).write(to: url)
        return try MappedFile(url: url)
    }

    private struct Document {
        let source: any DocumentSource
        let file: MappedFile
        var index: NodeIndex
        var full: NodeIndex { source.completeNodeIndex(overlaying: index) }
    }

    /// A large file as it opens: only the root is in the index.
    private func open(_ text: String, csv: Bool) throws -> Document {
        let file = try mapped(text, ext: csv ? "csv" : "json")
        let source: any DocumentSource = csv ? CSVSource(file: file) : try JSONSource(file: file)
        let root = try XCTUnwrap(source.node(for: source.rootID, parent: nil))
        return Document(source: source, file: file, index: NodeIndex(root: root))
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    private func json(_ data: Data) throws -> NSObject {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? NSObject)
    }

    /// Every serialization of `doc` from its source matches the whole document's.
    private func assertSerializesLikeTheWholeDocument(_ doc: Document, csv: Bool, _ label: String,
                                                      line: UInt = #line) throws {
        let full = doc.full
        if csv {
            XCTAssertEqual(text(try CSVDocumentSerializer(index: doc.index, source: doc.source)
                                    .serializeInSourceLayout()),
                           text(try CSVDocumentSerializer(index: full).serializeInSourceLayout()),
                           "\(label): save", line: line)
        }
        for format in FormatConverter.TargetFormat.allCases {
            let expected = Result { try FormatConverter().convert(index: full, mappedFile: doc.file,
                                                                  to: format) }
            let lazy = Result { try FormatConverter().convert(index: doc.index, mappedFile: doc.file,
                                                              source: doc.source, to: format) }
            switch (lazy, expected) {
            case (.success(let l), .success(let e)) where format == .json:
                // Unloaded JSON is copied as spelled, so compare values.
                XCTAssertEqual(try json(l), try json(e), "\(label): \(format)", line: line)
            case (.success(let l), .success(let e)):
                XCTAssertEqual(text(l), text(e), "\(label): \(format)", line: line)
            case (.failure, .failure):
                break
            default:
                XCTFail("\(label): \(format) gave \(lazy), whole document \(expected)", line: line)
            }
        }
    }

    private let csvs = [
        ("header", "name,age,city\nalice,30,Lund\nbob,,\"Malmö, SE\"\ncarol,41,\"say \"\"hi\"\"\"\n"),
        ("ragged", "a,b\n1,2\n3,4,5\n6\n"),
        ("no header", "1,2\n3,4\n5,6\n"),
        ("semicolons", "x;y\n1;2\n3;4\n"),
    ]

    private let jsons = [
        ("rows", #"[{"a":1,"b":"x"},{"a":2.5,"b":null},{"a":true,"b":"y\nz"}]"#),
        ("nested", #"{"users":[{"name":"alice","tags":["a",{"k":[]}]}],"n":1e3,"s":"é"}"#),
        ("ragged rows", #"[{"a":1},{"a":2,"b":3}]"#),
    ]

    // MARK: - Unloaded

    func testUnloadedFilesSerializeLikeTheWholeDocument() throws {
        for (label, text) in csvs {
            try assertSerializesLikeTheWholeDocument(try open(text, csv: true), csv: true, label)
        }
        for (label, text) in jsons {
            try assertSerializesLikeTheWholeDocument(try open(text, csv: false), csv: false, label)
        }
    }

    /// The CSV file's own bytes are not JSON (#74).
    func testACSVFileSavedAsJSONIsJSON() throws {
        let doc = try open("name,age\nalice,30\nbob,7\n", csv: true)
        let data = try JSONDocumentSerializer(index: doc.index, mappedFile: doc.file,
                                              source: doc.source).serialize(pretty: false)
        XCTAssertEqual(try json(data), try json(Data(#"[{"name":"alice","age":30},{"name":"bob","age":7}]"#.utf8)))
    }

    /// A row's cell for a column is its first member with that key, wherever
    /// it is in the row.
    func testCSVTakesEachRowsFirstMemberForAColumn() throws {
        let doc = try open(#"[{"a":1,"b":2},{"b":3,"a":4},{"a":5,"a":6,"b":7},{"b":8}]"#, csv: false)
        for index in [doc.index, doc.full] {
            let csv = text(try CSVDocumentSerializer(index: index, source: doc.source)
                                .serializeInSourceLayout())
            XCTAssertEqual(csv, "a,b\n1,2\n4,3\n5,7\n,8\n")
        }
    }

    // MARK: - Edited

    /// The CSV with its second row's age changed, first row deleted, and an
    /// empty row inserted at the end.
    private func editedCSV() throws -> Document {
        var doc = try open(csvs[0].1, csv: true)
        let root = try XCTUnwrap(doc.index.root)
        let rows = root.childIDs.compactMap { doc.source.node(for: $0, parent: root) }
        var loaded = [NodeID: DocumentNode]()
        for row in rows {
            loaded[row.id] = row
            for kvID in row.childIDs {
                let kv = try XCTUnwrap(doc.source.node(for: kvID, parent: row))
                loaded[kvID] = kv
                for id in kv.childIDs { loaded[id] = doc.source.node(for: id, parent: kv) }
            }
        }
        doc.index.applySnapshot(loaded)
        let ageKV = try XCTUnwrap(doc.index.children(of: rows[1].id).first { $0.key == "age" })
        let age = try XCTUnwrap(doc.index.children(of: ageKV.id).first)
        doc.index.updateNode(age.id) { $0.value = .scalar(.integer(99)) }
        doc.index = try XCTUnwrap(EditTransaction.removeNode(rows[0].id, in: doc.index))
            .applying(to: doc.index)
        let inserted = DocumentNode(type: .object, depth: 1, parentID: root.id,
                                    value: .container(childCount: 0))
        doc.index.insertChild(inserted, in: root.id, at: 2)
        return doc
    }

    func testEditedFilesSerializeLikeTheWholeDocument() throws {
        let doc = try editedCSV()
        try assertSerializesLikeTheWholeDocument(doc, csv: true, "edited csv")
        let saved = text(try CSVDocumentSerializer(index: doc.index, source: doc.source)
                            .serializeInSourceLayout())
        XCTAssertFalse(saved.contains("alice"))
        XCTAssertTrue(saved.contains("bob,99,"))
    }

    func testEditsDeepInAnUnloadedJSONFileAreExported() throws {
        var doc = try open(jsons[1].1, csv: false)
        // Load the path down to "alice", as expanding it would, and edit it.
        let full = doc.full
        let alice = try XCTUnwrap(full.nodesMatching {
            if case .scalar(.string("alice")) = $0.value { return true } else { return false }
        }.first)
        var path = [NodeID: DocumentNode]()
        var current: DocumentNode? = alice
        while let node = current {
            path[node.id] = node
            current = node.parentID.flatMap { full.node(for: $0) }
        }
        doc.index.applySnapshot(path)
        doc.index.updateNode(alice.id) { $0.value = .scalar(.string("ALICE")) }
        try assertSerializesLikeTheWholeDocument(doc, csv: false, "edited json")
        let yaml = text(try FormatConverter().convert(index: doc.index, source: doc.source, to: .yaml))
        XCTAssertTrue(yaml.contains("ALICE"))
    }
}
