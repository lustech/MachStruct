import Foundation

// MARK: - TestCorpusGenerator

/// Generates standardised JSON test files at various sizes and structural
/// characteristics.  All files are written to a shared temporary directory and
/// cached between test runs so generation only happens once per process.
///
/// File inventory (approximate sizes):
/// | Name                    | Size   | Key characteristic                        |
/// |-------------------------|--------|-------------------------------------------|
/// | tiny.json               | ~1 KB  | Simple nested object                      |
/// | medium.json             | ~1 MB  | 5 K nodes, mixed types, Foundation path   |
/// | large.json              | ~10 MB | 50 K nodes, deep nesting, simdjson path   |
/// | huge.json               | ~100MB | Wide array, large text blobs, simdjson    |
/// | pathological_deep.json  | ~500KB | Nesting depth 200, stress recursion stack |
/// | pathological_wide.json  | ~10 MB | Flat array of 50 K objects                |
/// | malformed.json          | ~1 KB  | Trailing comma — invalid JSON             |
struct TestCorpusGenerator {

    // MARK: - Corpus cases

    enum Corpus: CaseIterable {
        case tiny
        case medium
        case large
        case huge
        case pathologicalDeep
        case pathologicalWide
        case malformed

        var fileName: String {
            switch self {
            case .tiny:              return "tiny.json"
            case .medium:            return "medium.json"
            case .large:             return "large.json"
            case .huge:              return "huge.json"
            case .pathologicalDeep: return "pathological_deep.json"
            case .pathologicalWide: return "pathological_wide.json"
            case .malformed:         return "malformed.json"
            }
        }
    }

    // MARK: - Storage

    let directory: URL

    init(directory: URL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("MachStructTestCorpus",
                                                    isDirectory: true)) {
        self.directory = directory
    }

    /// Creates the corpus directory. Call once in `setUpWithError()`.
    func prepare() throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    /// Returns the URL for a corpus file, generating it if it does not yet exist.
    func url(for corpus: Corpus) throws -> URL {
        let url = directory.appendingPathComponent(corpus.fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            try generate(corpus, to: url)
        }
        return url
    }

    /// Deletes all cached corpus files (useful for forced regeneration).
    func purge() throws {
        for corpus in Corpus.allCases {
            let url = directory.appendingPathComponent(corpus.fileName)
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Dispatch

    private func generate(_ corpus: Corpus, to url: URL) throws {
        switch corpus {
        case .tiny:              try generateTiny(to: url)
        case .medium:            try generateMedium(to: url)
        case .large:             try generateLarge(to: url)
        case .huge:              try generateHuge(to: url)
        case .pathologicalDeep: try generatePathologicalDeep(to: url)
        case .pathologicalWide: try generatePathologicalWide(to: url)
        case .malformed:         try generateMalformed(to: url)
        }
    }
}

// MARK: - Generators

private extension TestCorpusGenerator {

    // -------------------------------------------------------------------------
    // MARK: tiny (~1 KB)
    // -------------------------------------------------------------------------

    func generateTiny(to url: URL) throws {
        let json = """
        {
          "name": "Alice",
          "age": 30,
          "active": true,
          "score": 98.6,
          "address": {
            "street": "123 Main St",
            "city": "Springfield",
            "state": "IL",
            "zip": "62701"
          },
          "tags": ["swift", "json", "parser", "macos"],
          "metadata": {
            "version": 1,
            "created": "2024-01-15",
            "source": null
          }
        }
        """
        try json.data(using: .utf8)!.write(to: url)
    }

    // -------------------------------------------------------------------------
    // MARK: medium (~1 MB, Foundation path — stays below 5 MB threshold)
    // -------------------------------------------------------------------------

    func generateMedium(to url: URL) throws {
        // ~400 user records × ~2.5 KB each ≈ 1 MB
        var out = Data()
        out.reserveCapacity(1_100_000)

        func w(_ s: String) { out.append(contentsOf: s.utf8) }

        w("[\n")
        let count = 400
        for i in 0..<count {
            let active  = i % 3 != 0
            let score   = Double(i) * 2.718
            let day     = String(format: "%02d", (i % 28) + 1)
            let month   = String(format: "%02d", (i % 12) + 1)
            w("""
            {
              "id": \(i),
              "name": "User \(i)",
              "email": "user\(i)@example.com",
              "score": \(String(format: "%.4f", score)),
              "active": \(active),
              "created": "2024-\(month)-\(day)",
              "level": \(i % 10),
              "role": "\(["admin","editor","viewer","guest"][i % 4])",
              "tags": ["tag\(i % 5)", "tag\(i % 7)", "tag\(i % 11)"],
              "address": {
                "city": "City\(i % 100)",
                "country": "Country\(i % 50)",
                "zip": "\(String(format: "%05d", 10000 + i % 89999))"
              },
              "preferences": {
                "theme": "\(["light","dark","system"][i % 3])",
                "notifications": \(i % 2 == 0),
                "language": "\(["en","es","fr","de","ja"][i % 5])"
              },
              "stats": {
                "logins": \(i * 7),
                "posts": \(i * 3),
                "comments": \(i * 11),
                "likes": \(i * 23)
              }
            }
            """)
            if i < count - 1 { w(",\n") }
        }
        w("\n]")
        try out.write(to: url)
    }

    // -------------------------------------------------------------------------
    // MARK: large (~10 MB, simdjson path)
    // -------------------------------------------------------------------------

    func generateLarge(to url: URL) throws {
        // ~5 000 records × ~2 KB each ≈ 10 MB
        // Nodes per record ≈ 1(obj)+10(kv)+10(scalar)+1(arr)+3(scalars) ≈ 25
        // Total ≈ 125 000 nodes
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }

        func w(_ s: String) throws { try fh.write(contentsOf: Data(s.utf8)) }

        try w("[\n")
        let count = 5_000
        for i in 0..<count {
            let score  = Double(i) * 3.14159
            let day    = String(format: "%02d", (i % 28) + 1)
            let month  = String(format: "%02d", (i % 12) + 1)
            let record = """
            {"id":\(i),"name":"Record \(i)","email":"rec\(i)@corp.example","score":\(String(format:"%.6f",score)),"active":\(i%2==0),"created":"2024-\(month)-\(day)T\(String(format:"%02d",i%24)):00:00Z","priority":\(i%5),"category":"\(["alpha","beta","gamma","delta","epsilon"][i%5])","tags":["t\(i%8)","t\(i%13)","t\(i%17)"],"address":{"street":"\(i) Oak Avenue","city":"City\(i%200)","state":"ST","zip":"\(String(format:"%05d",i%100000))","country":"US"},"meta":{"version":\(i%10),"seq":\(i),"checksum":\(i*31%65536)}}
            """
            if i > 0 { try w(",\n") }
            try w(record)
        }
        try w("\n]")
    }

    // -------------------------------------------------------------------------
    // MARK: huge (~100 MB, simdjson path)
    //
    // Strategy: wide array of objects each containing a ~1 000-char text blob.
    // This keeps total node count ~490 K (well within the initial buffer budget)
    // while pushing file size to 100 MB, exercising simdjson throughput.
    // -------------------------------------------------------------------------

    func generateHuge(to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }

        func w(_ s: String) throws { try fh.write(contentsOf: Data(s.utf8)) }

        // Pad string of 1 000 'A's — represents a large text blob.
        let blob = String(repeating: "A", count: 1_000)

        try w("[\n")
        // Each entry ≈ 1 040 bytes → 100 MB / 1 040 ≈ 96 000 entries
        let target = 100 * 1_024 * 1_024   // 100 MB
        var written = 2                     // "[\n"
        var i = 0

        while written < target {
            let record = "{\"id\":\(i),\"text\":\"\(blob)\",\"n\":\(i)}"
            if i > 0 { try w(",\n"); written += 2 }
            try w(record)
            written += record.utf8.count
            i += 1
        }
        try w("\n]")
    }

    // -------------------------------------------------------------------------
    // MARK: pathological_deep (~500 KB, depth 200)
    //
    // Chain of nested objects 200 levels deep, each level holding a small array
    // of strings.  Stress-tests the parser's recursion handling.
    // -------------------------------------------------------------------------

    func generatePathologicalDeep(to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }

        func w(_ s: String) throws { try fh.write(contentsOf: Data(s.utf8)) }

        let depth = 200

        // Open depth levels, writing items at each.
        for d in 0..<depth {
            if d == 0 { try w("{") }
            // Write items array at this level
            try w("\"depth\":\(d),\"items\":[")
            for j in 0..<100 {
                if j > 0 { try w(",") }
                try w("\"v\(d)_\(j)\"")
            }
            try w("]")
            if d < depth - 1 { try w(",\"next\":{") }
        }

        // Close all open objects.
        for _ in 0..<depth {
            try w("}")
        }
    }

    // -------------------------------------------------------------------------
    // MARK: pathological_wide (~10 MB, 50 K objects in a flat array)
    // -------------------------------------------------------------------------

    func generatePathologicalWide(to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }

        func w(_ s: String) throws { try fh.write(contentsOf: Data(s.utf8)) }

        try w("[")
        let count = 50_000
        for i in 0..<count {
            if i > 0 { try w(",") }
            try w("{\"i\":\(i),\"v\":\(Double(i)*0.001),\"s\":\"item_\(i)\"}")
        }
        try w("]")
    }

    // -------------------------------------------------------------------------
    // MARK: malformed (~1 KB, trailing comma — invalid JSON)
    // -------------------------------------------------------------------------

    func generateMalformed(to url: URL) throws {
        // Uses syntax errors that every strict JSON parser rejects:
        //  • Unquoted key (bad_key)
        //  • Missing closing brace (truncated)
        let json = #"{"valid": 1, bad_key: 2, "truncated": "#
        try json.data(using: .utf8)!.write(to: url)
    }
}
