import XCTest
import Yams
@testable import MachStructCore

/// YAML files are indexed from libyaml's events without composing a tree.
/// The entries must be exactly those composing and walking gives, and what
/// the indexer leaves to the composer must fall back to it.
final class YAMLEventIndexerTests: XCTestCase {

    /// An entry as compared: everything but its ID, with its parent as a
    /// position. `parsedValue` is compared by description, so NaN matches.
    private struct Shape: Equatable, CustomStringConvertible {
        let type: NodeType
        let depth: UInt16
        let parent: Int?
        let childCount: UInt32
        let key: String?
        let value: String?
        let metadata: YAMLMetadata?

        var description: String {
            "\(type) d\(depth) p\(parent.map(String.init) ?? "-") n\(childCount) k\(key ?? "-") v\(value ?? "-") \(metadata.map { "\($0)" } ?? "")"
        }
    }

    private func shapes(_ entries: [IndexEntry]) -> [Shape] {
        let position = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.id, $0) })
        return entries.map { entry in
            var meta: YAMLMetadata?
            if case .yaml(let m)? = entry.metadata { meta = m }
            return Shape(type: entry.nodeType, depth: entry.depth,
                         parent: entry.parentID.flatMap { position[$0] },
                         childCount: entry.childCount, key: entry.key,
                         value: entry.parsedValue.map { "\($0)" }, metadata: meta)
        }
    }

    private func events(_ yaml: String) -> [IndexEntry]? {
        var bytes = Array(yaml.utf8)
        if bytes.isEmpty { bytes = [0] }
        return bytes.withUnsafeBytes { YAMLEventIndexer.entries($0.baseAddress!, count: yaml.utf8.count) }
    }

    /// What `buildIndex` gave before: the documents composed and walked.
    private func composed(_ yaml: String) throws -> [IndexEntry] {
        try YAMLParser().indexEntries(composing: yaml)
    }

    private func assertMatchesComposing(_ yaml: String, file: StaticString = #filePath,
                                        line: UInt = #line) throws {
        let expected = shapes(try composed(yaml))
        let actual = try XCTUnwrap(events(yaml), "fell back: \(yaml.debugDescription)",
                                   file: file, line: line)
        XCTAssertEqual(shapes(actual), expected, yaml.debugDescription, file: file, line: line)
    }

    // MARK: - Equivalence

    private let samples = [
        "", "   \n\n", "# only a comment\n", "a: 1", "- x", "plain", "'quoted'", "\"dq\"",
        """
        name: alice
        age: 30
        height: 1.75
        nothing: ~
        empty:
        yes_: yes
        off_: Off
        nulls: [null, Null, NULL, ~, '']
        bools: [true, True, TRUE, false, no, NO, on, ON]
        ints: [0, -1, +7, 1_000, 0x1F, 0o17, 017, 0b101, 1:30, 9223372036854775807, 9223372036854775808]
        floats: [1.5, -0.0, 1e3, .5, .inf, -.Inf, .nan, .NaN, 1.0e+3, 1:30.5]
        others: [2001-12-14, 2001-12-14t21:59:43.10-05:00, '<<', =, 'true', "1"]
        """,
        """
        tagged:
          s: !!str 123
          i: !!int "42"
          i2: !!int 0x1F
          f: !!float 1
          b: !!bool "yes"
          n: !!null ""
          custom: !thing value
          local: !<tag:example.com,2000:x> y
          nonspecific: ! 12
          seq: !!seq [a]
          map: !custom {a: 1}
        """,
        """
        %TAG ! tag:example.com,2000:app/
        ---
        a: !foo bar
        """,
        """
        %YAML 1.1
        ---
        x: 1
        ...
        """,
        """
        block: |
          line one
          line two
        folded: >-
          folded
          text
        kept: |+
          keep

        tagged_block: !!str |
          12
        custom_block: !note >
          hi
        """,
        """
        anchors:
          base: &base {a: 1, b: [x, y]}
          list: &items
            - &first one
            - two
          scalar: &s 3
        """,
        "flow: {a: [1, {b: c}], 'd e': \"f\\tg\", empty: {}, none: []}",
        "- - - deep\n    - x\n  - y\n- {}\n- []\n-\n- ''",
        "\"key with: colon\": v\n'single': w\n? plain explicit\n: z\n\"\": empty key",
        "unicode: héllo wörld ✓ 𝄞\n键: 值\nnul: \"a\\0b\"\nesc: \"\\u00e9\\n\\x41\"",
        "\u{FEFF}bom: true",
        "a: 1\n---\nb: 2\n",
        "---\n---\n...\n---\nx\n",
        "--- 1\n--- [a, b]\n--- {c: d}\n--- |\n  text\n",
        "--- &doc\nanchored: doc\n",
        "<<: {a: 1}\nmerge_like: <<\n",
        "k1: v\nK1: v\n'k2': x\nk 2: y\n",
        "deep: " + String(repeating: "[", count: 50) + "x" + String(repeating: "]", count: 50),
        (0..<40).map { "key\($0): \($0)" }.joined(separator: "\n"),
    ]

    func testEntriesMatchComposing() throws {
        for yaml in samples { try assertMatchesComposing(yaml) }
    }

    /// Random documents in every style, emitted by Yams.
    func testRandomDocumentsMatchComposing() throws {
        var rng = SystemRandomNumberGenerator()
        let words: [String] = ["a", "b", "x y", "", "~", "null", "Yes", "off", "12", "-3", "0x1F",
                               "1_000", "1.5", ".inf", ".NaN", "1e3", "2001-12-14", "<<", "=",
                               "with: colon", "#hash", "tab\there", "line\nbreak", "é", "'q'",
                               "\"dq\"", " lead", "trail ", "- dash", "[", "{", "&a", "*a", "!t"]
        let styles: [Node.Scalar.Style] = [.plain, .singleQuoted, .doubleQuoted, .literal, .folded, .any]
        let tags: [Tag] = [.implicit, Tag(.str), Tag(.int), Tag(.float), Tag(.bool), Tag(.null),
                           Tag("!custom")]
        var keyCounter = 0

        func scalar() -> Node {
            .scalar(.init(words.randomElement(using: &rng)!, tags.randomElement(using: &rng)!,
                          styles.randomElement(using: &rng)!))
        }
        func node(_ depth: Int) -> Node {
            switch depth > 3 ? 0 : Int.random(in: 0..<3, using: &rng) {
            case 0: return scalar()
            case 1:
                return .sequence(.init((0..<Int.random(in: 0...4, using: &rng)).map { _ in node(depth + 1) },
                                       .implicit, Bool.random(using: &rng) ? .flow : .block))
            default:
                let pairs: [(Node, Node)] = (0..<Int.random(in: 0...4, using: &rng)).map { _ in
                    keyCounter += 1
                    let key = Node.scalar(.init("\(words.randomElement(using: &rng)!)\(keyCounter)",
                                                .implicit, styles.randomElement(using: &rng)!))
                    return (key, node(depth + 1))
                }
                return .mapping(.init(pairs, .implicit, Bool.random(using: &rng) ? .flow : .block))
            }
        }

        for _ in 0..<300 {
            let documents = (0..<Int.random(in: 1...3, using: &rng)).map { _ in node(0) }
            let yaml = try Yams.serialize(nodes: documents)
            try assertMatchesComposing(yaml)
        }
    }

    // MARK: - Reserving

    func testEntryCountIsEstimatedFromTheFirstEvents() throws {
        let yaml = "items:\n" + (0..<5_000).map { "  - {id: \($0), name: 'n\($0)', tags: [a, b]}" }
            .joined(separator: "\n")
        let actual = try XCTUnwrap(events(yaml)).count
        let bytes = Array(yaml.utf8)
        let estimate = bytes.withUnsafeBytes {
            YAMLEventIndexer.estimatedEntryCount($0.baseAddress!, count: $0.count, sampleSize: 16_384)
        }
        XCTAssertEqual(Double(estimate), Double(actual), accuracy: Double(actual) * 0.1)
        // A file the sample covers isn't estimated: it is small.
        XCTAssertEqual(bytes.withUnsafeBytes {
            YAMLEventIndexer.estimatedEntryCount($0.baseAddress!, count: $0.count)
        }, 0)
    }

    // MARK: - Falling back

    func testWhatTheComposerResolvesFallsBack() throws {
        let fallBack = [
            "a: &x 1\nb: *x",                 // alias
            "base: &b {k: v}\nuse:\n  <<: *b", // merge through an alias
            "a: 1\na: 2",                      // duplicate key: the composer rejects it
            (0..<20).map { "k\($0): v" }.joined(separator: "\n") + "\nk3: again",
            "1: a\n\"1\": b",                  // same text, different tags: it keeps both
            "? [a, b]\n: c",                   // a key that isn't a scalar
            "? {a: b}\n: c",
            "a: [",                            // errors: the composer builds the message
            "key: \"unterminated",
            "a:\n  - b\n c: d",
        ]
        for yaml in fallBack {
            XCTAssertNil(events(yaml), yaml)
        }
        let invalidUTF8: [UInt8] = Array("a: ".utf8) + [0xC3, 0x28]
        XCTAssertNil(invalidUTF8.withUnsafeBytes { YAMLEventIndexer.entries($0.baseAddress!, count: $0.count) })
    }

    /// `buildIndex` composes what the indexer declines, with the same
    /// result and errors as before.
    func testBuildIndexFallsBackToComposing() async throws {
        func build(_ yaml: String) async throws -> StructuralIndex {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("events-\(UUID().uuidString).yaml")
            try Data(yaml.utf8).write(to: url)
            return try await YAMLParser().buildIndex(from: MappedFile(url: url))
        }
        let aliased = "a: &x {k: v}\nb: *x"
        let aliasedIndex = try await build(aliased)
        XCTAssertEqual(shapes(aliasedIndex.entries), shapes(try composed(aliased)))
        // Anchors are kept on both paths (#79).
        func anchor(of key: String, in index: StructuralIndex) -> String? {
            guard let kv = index.entries.firstIndex(where: { $0.key == key }),
                  case .yaml(let meta)? = index.entries[kv + 1].metadata else { return nil }
            return meta.anchor
        }
        XCTAssertEqual(anchor(of: "a", in: aliasedIndex), "x")
        let anchored = try await build("a: &y [1]\nb: 2")
        XCTAssertEqual(anchor(of: "a", in: anchored), "y")
        let tags = "1: a\n\"1\": b"
        let tagsIndex = try await build(tags)
        XCTAssertEqual(shapes(tagsIndex.entries), shapes(try composed(tags)))

        do {
            _ = try await build("a: 1\na: 2")
            XCTFail("a duplicate key must be rejected")
        } catch {}
        do {
            _ = try await build("a: [")
            XCTFail("a syntax error must be reported")
        } catch let error as ParseError {
            XCTAssertNotNil(error.line)
        }
    }
}
