import XCTest
@testable import MachStructCore

final class XMLParserTests: XCTestCase {

    // MARK: - Helpers

    private func makeFile(xml: String) throws -> MappedFile {
        let data = xml.data(using: .utf8)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).xml")
        try data.write(to: url)
        return try MappedFile(url: url)
    }

    private func buildIndex(xml: String) async throws -> StructuralIndex {
        let file = try makeFile(xml: xml)
        return try await XMLParser().buildIndex(from: file)
    }

    private func xmlMeta(_ entry: IndexEntry, file: StaticString = #file, line: UInt = #line) -> XMLMetadata? {
        guard case .xml(let m) = entry.metadata else {
            XCTFail("Expected .xml metadata", file: file, line: line)
            return nil
        }
        return m
    }

    // MARK: - Basic structure

    func testSingleSelfClosingElement() async throws {
        let index = try await buildIndex(xml: "<root/>")
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.entries[0].nodeType, .object)
        XCTAssertEqual(index.entries[0].key, "root")
        XCTAssertEqual(index.entries[0].depth, 0)
        XCTAssertNil(index.entries[0].parentID)
        XCTAssertEqual(index.entries[0].childCount, 0)
    }

    func testSelfClosingMetadata() async throws {
        let index = try await buildIndex(xml: "<root/>")
        let meta = xmlMeta(index.entries[0])
        XCTAssertEqual(meta?.isSelfClosing, true)
        XCTAssertTrue(meta?.attributes.isEmpty == true)
    }

    func testEmptyElementWithTags() async throws {
        let index = try await buildIndex(xml: "<root></root>")
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.entries[0].childCount, 0)
        XCTAssertEqual(xmlMeta(index.entries[0])?.isSelfClosing, true)
    }

    func testTextContent() async throws {
        let index = try await buildIndex(xml: "<root>hello</root>")
        // root(object) + "hello"(scalar)
        XCTAssertEqual(index.entries.count, 2)
        XCTAssertEqual(index.entries[0].nodeType, .object)
        XCTAssertEqual(index.entries[0].childCount, 1)
        XCTAssertEqual(index.entries[0].key, "root")
        XCTAssertFalse(xmlMeta(index.entries[0])?.isSelfClosing == true)

        XCTAssertEqual(index.entries[1].nodeType, .scalar)
        XCTAssertEqual(index.entries[1].parsedValue, .string("hello"))
        XCTAssertEqual(index.entries[1].parentID, index.entries[0].id)
        XCTAssertEqual(index.entries[1].depth, 1)
    }

    func testNestedElements() async throws {
        let index = try await buildIndex(xml: "<root><child1/><child2/></root>")
        XCTAssertEqual(index.entries.count, 3)
        XCTAssertEqual(index.entries[0].key, "root")
        XCTAssertEqual(index.entries[0].childCount, 2)
        XCTAssertEqual(index.entries[1].key, "child1")
        XCTAssertEqual(index.entries[1].depth, 1)
        XCTAssertEqual(index.entries[1].parentID, index.entries[0].id)
        XCTAssertEqual(index.entries[2].key, "child2")
        XCTAssertEqual(index.entries[2].depth, 1)
        XCTAssertEqual(index.entries[2].parentID, index.entries[0].id)
    }

    func testDeeplyNested() async throws {
        let index = try await buildIndex(xml: "<a><b><c/></b></a>")
        XCTAssertEqual(index.entries.count, 3)
        XCTAssertEqual(index.entries[0].depth, 0)
        XCTAssertEqual(index.entries[1].depth, 1)
        XCTAssertEqual(index.entries[2].depth, 2)
        XCTAssertNil(index.entries[0].parentID)
        XCTAssertEqual(index.entries[1].parentID, index.entries[0].id)
        XCTAssertEqual(index.entries[2].parentID, index.entries[1].id)
    }

    func testElementWithChildAndText() async throws {
        let index = try await buildIndex(xml: "<root><item>text</item></root>")
        // root(obj) + item(obj) + "text"(scalar)
        XCTAssertEqual(index.entries.count, 3)
        XCTAssertEqual(index.entries[0].childCount, 1)   // root has 1 child: item
        XCTAssertEqual(index.entries[1].childCount, 1)   // item has 1 child: text
        XCTAssertEqual(index.entries[2].parsedValue, .string("text"))
    }

    // MARK: - Attributes

    func testSingleAttribute() async throws {
        let index = try await buildIndex(xml: #"<item id="42"/>"#)
        XCTAssertEqual(index.entries.count, 1)
        let meta = xmlMeta(index.entries[0])
        XCTAssertEqual(meta?.attributes.count, 1)
        XCTAssertEqual(meta?.attributes[0].key, "id")
        XCTAssertEqual(meta?.attributes[0].value, "42")
    }

    func testMultipleAttributesSorted() async throws {
        let index = try await buildIndex(xml: #"<item id="42" name="test" active="true"/>"#)
        let meta = xmlMeta(index.entries[0])
        // Attributes should be sorted alphabetically
        XCTAssertEqual(meta?.attributes.count, 3)
        XCTAssertEqual(meta?.attributes[0].key, "active")
        XCTAssertEqual(meta?.attributes[1].key, "id")
        XCTAssertEqual(meta?.attributes[2].key, "name")
    }

    func testAttributeWithText() async throws {
        let index = try await buildIndex(xml: #"<item id="1">content</item>"#)
        XCTAssertEqual(index.entries.count, 2)
        let meta = xmlMeta(index.entries[0])
        XCTAssertEqual(meta?.attributes[0].key, "id")
        XCTAssertEqual(index.entries[1].parsedValue, .string("content"))
    }

    // MARK: - XML declaration

    func testXMLDeclarationIgnored() async throws {
        let xml = #"<?xml version="1.0" encoding="UTF-8"?><root/>"#
        let index = try await buildIndex(xml: xml)
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.entries[0].key, "root")
    }

    // MARK: - Namespace

    func testNamespaceCapture() async throws {
        let xml = #"<ns:root xmlns:ns="http://example.com"><ns:child/></ns:root>"#
        let index = try await buildIndex(xml: xml)
        XCTAssertEqual(index.entries.count, 2)
        let rootMeta = xmlMeta(index.entries[0])
        XCTAssertEqual(rootMeta?.namespace, "http://example.com")
        let childMeta = xmlMeta(index.entries[1])
        XCTAssertEqual(childMeta?.namespace, "http://example.com")
    }

    func testNoNamespace() async throws {
        let index = try await buildIndex(xml: "<root/>")
        XCTAssertNil(xmlMeta(index.entries[0])?.namespace)
    }

    // MARK: - Mixed content

    func testMixedContent() async throws {
        // Text before and after a child element
        let xml = "<p>Hello <b>world</b>!</p>"
        let index = try await buildIndex(xml: xml)
        // p(obj), "Hello"(scalar), b(obj), "world"(scalar), "!"(scalar)
        XCTAssertEqual(index.entries.count, 5)
        XCTAssertEqual(index.entries[0].key, "p")
        XCTAssertEqual(index.entries[0].childCount, 3)  // "Hello", b, "!"

        XCTAssertEqual(index.entries[1].parsedValue, .string("Hello"))
        XCTAssertEqual(index.entries[1].parentID, index.entries[0].id)

        XCTAssertEqual(index.entries[2].key, "b")
        XCTAssertEqual(index.entries[2].childCount, 1)

        XCTAssertEqual(index.entries[3].parsedValue, .string("world"))
        XCTAssertEqual(index.entries[3].parentID, index.entries[2].id)

        XCTAssertEqual(index.entries[4].parsedValue, .string("!"))
        XCTAssertEqual(index.entries[4].parentID, index.entries[0].id)
    }

    func testWhitespaceOnlyTextIgnored() async throws {
        let xml = "<root>\n  <child/>\n</root>"
        let index = try await buildIndex(xml: xml)
        // Whitespace-only text between elements should produce no scalar nodes
        XCTAssertEqual(index.entries.count, 2)
        XCTAssertEqual(index.entries[0].childCount, 1)
    }

    // MARK: - NodeIndex integration

    func testBuildNodeIndex() async throws {
        let xml = "<root><item>value</item></root>"
        let file = try makeFile(xml: xml)
        let structural = try await XMLParser().buildIndex(from: file)
        let nodeIndex = structural.buildNodeIndex()

        let root = nodeIndex.node(for: nodeIndex.rootID)!
        XCTAssertEqual(root.key, "root")
        XCTAssertEqual(nodeIndex.children(of: nodeIndex.rootID).count, 1)

        let item = nodeIndex.children(of: nodeIndex.rootID)[0]
        XCTAssertEqual(item.key, "item")
        XCTAssertEqual(nodeIndex.children(of: item.id).count, 1)

        if case .xml(let meta) = item.metadata {
            XCTAssertFalse(meta.isSelfClosing)
        } else {
            XCTFail("Expected XML metadata on item node")
        }
    }

    func testMetadataPropagatedToDocumentNode() async throws {
        let xml = #"<root id="1"/>"#
        let file = try makeFile(xml: xml)
        let structural = try await XMLParser().buildIndex(from: file)
        let nodeIndex = structural.buildNodeIndex()
        let root = nodeIndex.node(for: nodeIndex.rootID)!
        if case .xml(let meta) = root.metadata {
            XCTAssertEqual(meta.attributes[0].key, "id")
        } else {
            XCTFail("Expected XML metadata on root DocumentNode")
        }
    }

    // MARK: - CDATA

    func testCDATASection() async throws {
        let xml = "<root><![CDATA[hello & world]]></root>"
        let index = try await buildIndex(xml: xml)
        XCTAssertEqual(index.entries.count, 2)
        XCTAssertEqual(index.entries[1].parsedValue, .string("hello & world"))
    }

    // MARK: - parseValue

    func testParseValueScalar() throws {
        let parser = XMLParser()
        let id = NodeID.generate()
        let entry = IndexEntry(id: id, nodeType: .scalar, depth: 1, parentID: nil,
                               parsedValue: .string("hello"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dummy.xml")
        try "<x/>".data(using: .utf8)!.write(to: tmp)
        let file = try MappedFile(url: tmp)
        let value = try parser.parseValue(entry: entry, from: file)
        XCTAssertEqual(value, .scalar(.string("hello")))
    }

    func testParseValueContainer() throws {
        let parser = XMLParser()
        let id = NodeID.generate()
        let entry = IndexEntry(id: id, nodeType: .object, depth: 0, parentID: nil, childCount: 3)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dummy2.xml")
        try "<x/>".data(using: .utf8)!.write(to: tmp)
        let file = try MappedFile(url: tmp)
        let value = try parser.parseValue(entry: entry, from: file)
        XCTAssertEqual(value, .container(childCount: 3))
    }

    // MARK: - Serialize

    func testSerializeString() throws {
        let parser = XMLParser()
        let data = try parser.serialize(value: .scalar(.string("hello")))
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello")
    }

    func testSerializeEscapesSpecialChars() throws {
        let parser = XMLParser()
        let data = try parser.serialize(value: .scalar(.string("<b> & </b>")))
        XCTAssertEqual(String(data: data, encoding: .utf8), "&lt;b&gt; &amp; &lt;/b&gt;")
    }

    func testSerializeContainerThrows() {
        let parser = XMLParser()
        XCTAssertThrowsError(try parser.serialize(value: .container(childCount: 1)))
    }

    // MARK: - Validation

    func testValidXML() async throws {
        let file = try makeFile(xml: "<root><item>a</item></root>")
        let issues = try await XMLParser().validate(file: file)
        XCTAssertTrue(issues.isEmpty)
    }

    func testUnclosedTagReportsError() async throws {
        let file = try makeFile(xml: "<root><unclosed>")
        let issues = try await XMLParser().validate(file: file)
        XCTAssertFalse(issues.isEmpty)
        XCTAssertEqual(issues[0].severity, .error)
    }

    // MARK: - Malformed XML throws

    func testMalformedXMLThrows() async throws {
        let file = try makeFile(xml: "<root><<bad/></root>")
        do {
            _ = try await XMLParser().buildIndex(from: file)
            XCTFail("Expected parse error")
        } catch {
            // expected
        }
    }

    // MARK: - Progressive streaming

    func testProgressiveStreamCompletesAndEmitsBatches() async throws {
        let items = (1...50).map { "<item>\($0)</item>" }.joined()
        let xml = "<root>\(items)</root>"
        let file = try makeFile(xml: xml)

        var batchCount = 0
        var didComplete = false

        for await progress in XMLParser().parseProgressively(file: file) {
            switch progress {
            case .nodesIndexed: batchCount += 1
            case .complete:     didComplete = true
            case .error(let e): XCTFail("Unexpected error: \(e)")
            case .warning:      break
            }
        }

        XCTAssertTrue(didComplete)
        XCTAssertGreaterThan(batchCount, 0)
    }

    // MARK: - Supported extensions

    func testSupportedExtensions() {
        XCTAssertTrue(XMLParser.supportedExtensions.contains("xml"))
        XCTAssertTrue(XMLParser.supportedExtensions.contains("xhtml"))
        XCTAssertTrue(XMLParser.supportedExtensions.contains("svg"))
    }
}
