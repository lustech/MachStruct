import XCTest
@testable import MachStructCore

/// Saving and exporting a large file stream its text to disk instead of
/// holding it whole. What is written must be exactly what serializing in
/// memory gives.
final class StreamedSerializationTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("streamed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    // MARK: - FileTextStream

    func testStreamWritesEverythingAcrossBufferBoundaries() throws {
        var rng = SystemRandomNumberGenerator()
        let pieces = ["a", "é", "𝄞", "\n", "", "long " + String(repeating: "x", count: 40), "ü✓"]
        for bufferSize in [1, 3, 7, 64, 1 << 20] {
            let url = file("buffer-\(bufferSize).txt")
            let stream = try FileTextStream(url: url, bufferSize: bufferSize)
            var expected = ""
            for _ in 0..<500 {
                let piece = pieces.randomElement(using: &rng)!
                stream.write(piece)
                expected += piece
            }
            try stream.close()
            try stream.close()   // closing twice is harmless
            XCTAssertEqual(try Data(contentsOf: url), Data(expected.utf8), "buffer \(bufferSize)")
        }
    }

    func testStreamThatCannotOpenThrows() {
        XCTAssertThrowsError(try FileTextStream(url: file("missing/dir/out.txt")))
    }

    func testWritingReplacesAFileOnlyOnceAllIsWritten() throws {
        let url = file("out.txt")
        try Data("old".utf8).write(to: url)

        struct Failure: Error {}
        XCTAssertThrowsError(try FileTextStream.write(to: url) { stream in
            stream.write("partial")
            throw Failure()
        })
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old")

        try FileTextStream.write(to: url) { $0.write("new") }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")

        let fresh = file("fresh.txt")
        try FileTextStream.write(to: fresh) { $0.write("made") }
        XCTAssertEqual(try String(contentsOf: fresh, encoding: .utf8), "made")
    }

    func testFileWrapperHoldsTheTextAndLeavesNoFile() throws {
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()))
        let wrapper = try FileTextStream.fileWrapper { stream in
            for i in 0..<10_000 { stream.write("line \(i)\n") }
        }
        let expected = (0..<10_000).map { "line \($0)\n" }.joined()
        XCTAssertEqual(wrapper.regularFileContents, Data(expected.utf8))
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()))
        XCTAssertTrue(after.subtracting(before).filter { $0.hasPrefix("save-") }.isEmpty)

        let saved = file("saved.txt")
        try wrapper.write(to: saved, options: [], originalContentsURL: nil)
        XCTAssertEqual(try Data(contentsOf: saved), Data(expected.utf8))
    }

    // MARK: - Serializers

    private func mapped(_ text: String, ext: String) throws -> MappedFile {
        let url = file("source-\(UUID().uuidString).\(ext)")
        try Data(text.utf8).write(to: url)
        return try MappedFile(url: url)
    }

    private let json = #"""
        [{"name":"alice","age":30,"tags":["a","b"],"note":"é ✓"},
         {"name":"bob","age":null,"nested":{"deep":[1,2.5,true]}},
         "loose", 7]
        """#
    private let csv = "name,age,city\nalice,30,Umeå\nbob,,\"Stock, holm\"\n"
    private let yaml = "# c\nusers:\n  - name: alice\n    tags: [a, b]\n  - name: bob\nmeta: {n: 2}\n"

    /// The sources of a large file of each format, opened with only the root.
    private func documents() throws -> [(String, any DocumentSource, NodeIndex, MappedFile)] {
        let jsonFile = try mapped(json, ext: "json")
        let csvFile = try mapped(csv, ext: "csv")
        let yamlFile = try mapped(yaml, ext: "yaml")
        let sources: [(String, any DocumentSource, MappedFile)] = [
            ("json", try JSONSource(file: jsonFile), jsonFile),
            ("csv", CSVSource(file: csvFile), csvFile),
            ("yaml", try XCTUnwrap(YAMLSource(file: yamlFile)), yamlFile),
        ]
        return try sources.map { label, source, file in
            (label, source, NodeIndex(root: try XCTUnwrap(source.node(for: source.rootID, parent: nil))), file)
        }
    }

    func testExportsStreamWhatConvertingInMemoryGives() throws {
        for (label, source, index, file) in try documents() {
            for format in [FormatConverter.TargetFormat.json, .yaml, .csv] {
                let url = self.file("\(label).\(format.fileExtension)")
                let inMemory = Result {
                    try FormatConverter().convert(index: index, mappedFile: file, source: source, to: format)
                }
                let streamed = Result {
                    try FormatConverter().convert(index: index, mappedFile: file, source: source,
                                                  to: format, writingTo: url)
                    return try Data(contentsOf: url)
                }
                switch (inMemory, streamed) {
                case let (.success(a), .success(b)):
                    XCTAssertEqual(a, b, "\(label) → \(format)")
                case (.failure, .failure):
                    // CSV of a non-tabular document fails both ways and
                    // leaves nothing behind.
                    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "\(label) → \(format)")
                default:
                    XCTFail("\(label) → \(format): \(inMemory) vs \(streamed)")
                }
            }
        }
    }

    func testSavesStreamWhatSerializingInMemoryGives() throws {
        for (label, source, index, file) in try documents() {
            var streamed = ""
            let expected: Data
            switch label {
            case "json":
                let serializer = JSONDocumentSerializer(index: index, mappedFile: file, source: source)
                try serializer.write(to: &streamed, pretty: true)
                expected = try serializer.serialize(pretty: true)
                let wrapper = try FileTextStream.fileWrapper { stream in
                    var out = stream
                    try serializer.write(to: &out, pretty: true)
                }
                XCTAssertEqual(wrapper.regularFileContents, expected, label)
            case "csv":
                let serializer = CSVDocumentSerializer(index: index, source: source)
                try serializer.writeInSourceLayout(to: &streamed)
                expected = try serializer.serializeInSourceLayout()
            default:
                let serializer = YAMLDocumentSerializer(index: index, source: source)
                try serializer.write(to: &streamed)
                expected = try serializer.serialize()
            }
            XCTAssertEqual(Data(streamed.utf8), expected, label)
        }
    }
}
