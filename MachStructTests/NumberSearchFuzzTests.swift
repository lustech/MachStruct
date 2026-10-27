import XCTest
@testable import MachStructCore

/// Searching a large file's bytes skips numbers whose displayed text is
/// their bytes. Swift's number formatting decides that, so check it against
/// searching the nodes on numbers of every shape.
final class NumberSearchFuzzTests: XCTestCase {

    private func randomNumber(_ rng: inout SystemRandomNumberGenerator, json: Bool) -> String {
        var s = Bool.random(using: &rng) ? "-" : ""
        if !json, Int.random(in: 0..<10, using: &rng) == 0 { s = "+" }
        let intDigits = Int.random(in: 1...17, using: &rng)
        if Int.random(in: 0..<3, using: &rng) == 0 {
            s += "0"
        } else {
            s += String(Int.random(in: 1...9, using: &rng))
            s += (1..<intDigits).map { _ in String(Int.random(in: 0...9, using: &rng)) }.joined()
        }
        if Bool.random(using: &rng) {
            let zeros = Int.random(in: 0...5, using: &rng)
            s += "." + String(repeating: "0", count: zeros)
            s += (0..<Int.random(in: 0...12, using: &rng)).map { _ in
                String(Int.random(in: 0...9, using: &rng)) }.joined()
            if s.hasSuffix(".") { s += "0" }
        }
        if Int.random(in: 0..<6, using: &rng) == 0 {
            s += "e" + (Bool.random(using: &rng) ? "-" : "") + String(Int.random(in: 0...30, using: &rng))
        }
        return s
    }

    private func file(_ text: String, _ ext: String) throws -> MappedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("numbers-\(UUID().uuidString).\(ext)")
        try Data(text.utf8).write(to: url)
        return try MappedFile(url: url)
    }

    private func assertSearchesAgree(_ source: any DocumentSource, _ rng: inout SystemRandomNumberGenerator,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let shallow = NodeIndex(root: try XCTUnwrap(source.node(for: source.rootID, parent: nil)))
        let full = source.completeNodeIndex(overlaying: shallow)
        let alphabet = Array("0123456789.-e+").map(String.init)
        for _ in 0..<60 {
            let q = (0..<Int.random(in: 1...4, using: &rng)).map { _ in
                alphabet.randomElement(using: &rng)! }.joined()
            XCTAssertEqual(SearchEngine.search(query: q, in: shallow, source: source).map(\.matchedText),
                           SearchEngine.search(query: q, in: full).map(\.matchedText), q,
                           file: file, line: line)
        }
    }

    func testJSONNumbers() throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let numbers = (0..<200).map { _ in randomNumber(&rng, json: true) }
            let source = try JSONSource(file: file("[" + numbers.joined(separator: ",") + "]", "json"))
            try assertSearchesAgree(source, &rng)
        }
    }

    func testCSVNumbers() throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let rows = (0..<200).map { _ in randomNumber(&rng, json: false) }
            let source = CSVSource(file: try file("n\n" + rows.joined(separator: "\n") + "\n", "csv"))
            try assertSearchesAgree(source, &rng)
        }
    }
}
