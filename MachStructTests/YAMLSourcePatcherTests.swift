import XCTest
@testable import MachStructCore

/// Saving an edited YAML file rewrites only the edited tokens, so comments,
/// anchors, quoting and layout survive.
final class YAMLSourcePatcherTests: XCTestCase {

    private func index(_ yaml: String) async throws -> NodeIndex {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("patch-\(UUID().uuidString).yaml")
        try Data(yaml.utf8).write(to: url)
        return try await YAMLParser().buildIndex(from: MappedFile(url: url)).buildNodeIndex()
    }

    /// The value node under the key path `keys` (array items by index).
    private func node(_ index: NodeIndex, _ path: [String]) throws -> DocumentNode {
        var current = try XCTUnwrap(index.root)
        for step in path {
            let children = index.children(of: current.id)
            if current.type == .array, let i = Int(step) {
                current = children[i]
            } else {
                let kv = try XCTUnwrap(children.first { $0.key == step }, "no key \(step)")
                current = try XCTUnwrap(index.children(of: kv.id).first)
            }
        }
        return current
    }

    private func keyValue(_ index: NodeIndex, _ key: String) throws -> DocumentNode {
        let root = try XCTUnwrap(index.root)
        return try XCTUnwrap(index.children(of: root.id).first { $0.key == key })
    }

    private func setValue(_ yaml: String, _ value: ScalarValue,
                          at path: String...) async throws -> String? {
        var idx = try await index(yaml)
        let target = try node(idx, path)
        idx.updateNode(target.id) { $0.value = .scalar(value) }
        return YAMLSourcePatcher.patch(source: yaml, edited: idx)
    }

    // MARK: - Values

    func testValueEditKeepsComments() async throws {
        let yaml = "# people\nname: Alice # the first\nage: 30\n"
        let out = try await setValue(yaml, .string("Bob"), at: "name")
        XCTAssertEqual(out, "# people\nname: Bob # the first\nage: 30\n")
    }

    func testUneditedDocumentIsReturnedUnchanged() async throws {
        let yaml = "# c\na: 1   # spaced\n\nb: [x, y]\n"
        let out = YAMLSourcePatcher.patch(source: yaml, edited: try await index(yaml))
        XCTAssertEqual(out, yaml)
    }

    func testQuotingStyleIsKept() async throws {
        let double = try await setValue("a: \"Alice\"\n", .string("Bob"), at: "a")
        XCTAssertEqual(double, "a: \"Bob\"\n")
        let single = try await setValue("a: 'Alice'\n", .string("Bob"), at: "a")
        XCTAssertEqual(single, "a: 'Bob'\n")
    }

    func testStringThatWouldResolveAsAnotherTypeIsQuoted() async throws {
        let out = try await setValue("a: Alice\n", .string("true"), at: "a")
        XCTAssertEqual(out, "a: 'true'\n")
    }

    func testNumberEdit() async throws {
        let out = try await setValue("a: 1 # n\n", .integer(42), at: "a")
        XCTAssertEqual(out, "a: 42 # n\n")
    }

    func testAnchorOnEditedValueIsKept() async throws {
        let out = try await setValue("a: &x 1\nb: 2\n", .integer(3), at: "a")
        XCTAssertEqual(out, "a: &x 3\nb: 2\n")
    }

    func testFlowSequenceItemEdit() async throws {
        let out = try await setValue("tags: [red, green] # t\n", .string("blue"), at: "tags", "1")
        XCTAssertEqual(out, "tags: [red, blue] # t\n")
    }

    func testNestedBlockEdit() async throws {
        let yaml = "server:\n  # where\n  host: localhost\n  port: 80\n"
        let out = try await setValue(yaml, .integer(8080), at: "server", "port")
        XCTAssertEqual(out, "server:\n  # where\n  host: localhost\n  port: 8080\n")
    }

    func testNonASCIIBeforeTheValue() async throws {
        let out = try await setValue("namn: \"Åsa\" # ö\nö: 1\n", .integer(2), at: "ö")
        XCTAssertEqual(out, "namn: \"Åsa\" # ö\nö: 2\n")
    }

    func testCRLFLineEndingsAreKept() async throws {
        let out = try await setValue("a: 1\r\nb: 2\r\n", .integer(3), at: "b")
        XCTAssertEqual(out, "a: 1\r\nb: 3\r\n")
    }

    // MARK: - Keys

    func testKeyRenameKeepsComments() async throws {
        let yaml = "name: Alice # n\nage: 30 # a\n"
        var idx = try await index(yaml)
        let kv = try keyValue(idx, "age")
        idx.updateNode(kv.id) { $0.key = "years" }
        XCTAssertEqual(YAMLSourcePatcher.patch(source: yaml, edited: idx),
                       "name: Alice # n\nyears: 30 # a\n")
    }

    // MARK: - Falls back (nil)

    func testStructuralEditIsNotPatched() async throws {
        let yaml = "a: 1\nb: 2\n"
        var idx = try await index(yaml)
        idx.removeNode(try keyValue(idx, "b").id)
        XCTAssertNil(YAMLSourcePatcher.patch(source: yaml, edited: idx))
    }

    func testBlockScalarEditIsNotPatched() async throws {
        let out = try await setValue("text: |\n  line one\n  line two\n", .string("x"), at: "text")
        XCTAssertNil(out)
    }

    /// Editing an anchored value would change every alias to it as well.
    func testEditingAnAliasedValueIsNotPatched() async throws {
        let out = try await setValue("a: &x 1\nb: *x\n", .integer(3), at: "a")
        XCTAssertNil(out)
    }
}
