import Foundation

// MARK: - XMLParser

/// SAX-based XML parser using Foundation.XMLParser (libxml2 under the hood).
///
/// **Phase 1** — `buildIndex(from:)`:
///   Streams SAX callbacks into a flat `IndexEntry` array in document order.
///   Each XML element maps to an `.object` node. Non-empty text content becomes
///   a `.scalar` child. Attributes and namespace info are stored in `XMLMetadata`.
///
/// **Phase 2** — `parseValue(entry:from:)`:
///   Scalar text nodes have eagerly-populated `parsedValue`. Container nodes return
///   `.container(childCount:)`. No lazy re-read is required.
///
/// No additional SPM dependencies are needed — `Foundation.XMLParser` ships with macOS
/// and is a thin Swift wrapper around the system libxml2.
public actor XMLParser: StructParser {

    public static let supportedExtensions: Set<String> = ["xml", "xhtml", "svg"]

    public init() {}

    // MARK: - Phase 1

    public func buildIndex(from file: MappedFile) async throws -> StructuralIndex {
        let length = UInt32(min(file.fileSize, UInt64(UInt32.max)))
        let data = try file.data(offset: 0, length: length)
        let builder = SAXBuilder()
        let parser = Foundation.XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false

        guard parser.parse() else {
            throw builder.parseError ?? XMLParserError.parseFailed
        }
        return StructuralIndex(entries: builder.indexEntries())
    }

    // MARK: - Progressive streaming

    public nonisolated func parseProgressively(file: MappedFile) -> AsyncStream<ParseProgress> {
        AsyncStream { continuation in
            Task {
                do {
                    let parser = XMLParser()
                    let index = try await parser.buildIndex(from: file)
                    let batchSize = 1_000
                    var batch: [IndexEntry] = []
                    batch.reserveCapacity(batchSize)
                    for entry in index.entries {
                        batch.append(entry)
                        if batch.count == batchSize {
                            continuation.yield(.nodesIndexed(batch))
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                    if !batch.isEmpty {
                        continuation.yield(.nodesIndexed(batch))
                    }
                    continuation.yield(.complete(index))
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Phase 2

    public nonisolated func parseValue(entry: IndexEntry, from file: MappedFile) throws -> NodeValue {
        if let sv = entry.parsedValue { return .scalar(sv) }
        if entry.nodeType == .object { return .container(childCount: Int(entry.childCount)) }
        return .unparsed
    }

    // MARK: - Serialize

    public nonisolated func serialize(value: NodeValue) throws -> Data {
        switch value {
        case .scalar(let sv):
            let raw: String
            switch sv {
            case .string(let s):  raw = s
            case .integer(let n): raw = "\(n)"
            case .float(let f):   raw = "\(f)"
            case .boolean(let b): raw = b ? "true" : "false"
            case .null:           raw = ""
            }
            let escaped = raw
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return Data(escaped.utf8)
        case .container:
            throw XMLParserError.cannotSerializeContainer
        case .unparsed, .error:
            throw XMLParserError.noValueToSerialize
        }
    }

    // MARK: - Validate

    public func validate(file: MappedFile) async throws -> [ValidationIssue] {
        let length = UInt32(min(file.fileSize, UInt64(UInt32.max)))
        let data = try file.data(offset: 0, length: length)
        let collector = ValidationDelegate()
        let parser = Foundation.XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.issues
    }
}

// MARK: - SAXBuilder

/// Accumulates `IndexEntry` values from `Foundation.XMLParser` SAX callbacks.
///
/// Uses a mutable `BuildEntry` intermediate (value type, mutated in place via array
/// index access) so that `childCount` and `isSelfClosing` can be finalised in
/// `didEndElement` after the entry was appended in `didStartElement`.
private final class SAXBuilder: NSObject, Foundation.XMLParserDelegate {

    var parseError: Error?

    // MARK: - Mutable intermediate

    private struct BuildEntry {
        var id: NodeID
        var nodeType: NodeType
        var depth: UInt16
        var parentID: NodeID?
        var childCount: UInt32
        var key: String?
        var parsedValue: ScalarValue?
        var namespace: String?
        var attributes: [(key: String, value: String)]
        var isSelfClosing: Bool

        init(
            id: NodeID,
            nodeType: NodeType,
            depth: UInt16,
            parentID: NodeID? = nil,
            childCount: UInt32 = 0,
            key: String? = nil,
            parsedValue: ScalarValue? = nil,
            namespace: String? = nil,
            attributes: [(key: String, value: String)] = [],
            isSelfClosing: Bool = false
        ) {
            self.id = id
            self.nodeType = nodeType
            self.depth = depth
            self.parentID = parentID
            self.childCount = childCount
            self.key = key
            self.parsedValue = parsedValue
            self.namespace = namespace
            self.attributes = attributes
            self.isSelfClosing = isSelfClosing
        }
    }

    // MARK: - Stack frame

    private struct StackFrame {
        let entryIndex: Int     // index into buildEntries[] for this element
        let nodeID: NodeID
        let depth: UInt16
        var textBuffer: String = ""
    }

    private var buildEntries: [BuildEntry] = []
    private var stack: [StackFrame] = []

    // MARK: - Output

    func indexEntries() -> [IndexEntry] {
        buildEntries.map { be in
            let meta: FormatMetadata? = be.nodeType == .object
                ? .xml(XMLMetadata(
                    namespace: be.namespace,
                    attributes: be.attributes,
                    isSelfClosing: be.isSelfClosing))
                : nil
            return IndexEntry(
                id: be.id,
                nodeType: be.nodeType,
                depth: be.depth,
                parentID: be.parentID,
                childCount: be.childCount,
                key: be.key,
                parsedValue: be.parsedValue,
                metadata: meta
            )
        }
    }

    // MARK: - Text flush helper

    /// Flush any accumulated text in the current top-of-stack frame as a scalar child node.
    /// Called before adding a new child element so mixed-content text appears in document order.
    private func flushText(at frameIndex: Int) {
        let trimmed = stack[frameIndex].textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        stack[frameIndex].textBuffer = ""
        guard !trimmed.isEmpty else { return }

        let textID = NodeID.generate()
        buildEntries.append(BuildEntry(
            id: textID,
            nodeType: .scalar,
            depth: stack[frameIndex].depth + 1,
            parentID: stack[frameIndex].nodeID,
            parsedValue: .string(trimmed)
        ))
        buildEntries[stack[frameIndex].entryIndex].childCount += 1
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: Foundation.XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String]
    ) {
        // Flush any text accumulated in the parent before this element child.
        if !stack.isEmpty {
            flushText(at: stack.count - 1)
        }

        let nodeID = NodeID.generate()
        let parentID = stack.last?.nodeID
        let depth = UInt16(stack.count)
        let namespace: String? = (namespaceURI?.isEmpty == false) ? namespaceURI : nil
        let attrs = attributeDict.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }

        // Increment parent's child count for this element.
        if !stack.isEmpty {
            buildEntries[stack[stack.count - 1].entryIndex].childCount += 1
        }

        let entryIndex = buildEntries.count
        buildEntries.append(BuildEntry(
            id: nodeID,
            nodeType: .object,
            depth: depth,
            parentID: parentID,
            key: elementName,
            namespace: namespace,
            attributes: attrs
        ))

        stack.append(StackFrame(entryIndex: entryIndex, nodeID: nodeID, depth: depth))
    }

    func parser(_ parser: Foundation.XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].textBuffer += string
    }

    func parser(_ parser: Foundation.XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty, let text = String(data: CDATABlock, encoding: .utf8) else { return }
        stack[stack.count - 1].textBuffer += text
    }

    func parser(
        _ parser: Foundation.XMLParser,
        didEndElement _: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        guard let frame = stack.popLast() else { return }

        // Flush any trailing text as the last child of this element.
        let trimmedText = frame.textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            let textID = NodeID.generate()
            buildEntries.append(BuildEntry(
                id: textID,
                nodeType: .scalar,
                depth: frame.depth + 1,
                parentID: frame.nodeID,
                parsedValue: .string(trimmedText)
            ))
            buildEntries[frame.entryIndex].childCount += 1
        }

        // An element with no children is self-closing (or explicitly empty).
        if buildEntries[frame.entryIndex].childCount == 0 {
            buildEntries[frame.entryIndex].isSelfClosing = true
        }
    }

    func parser(_ parser: Foundation.XMLParser, parseErrorOccurred error: Error) {
        parseError = error
    }

    func parser(_ parser: Foundation.XMLParser, validationErrorOccurred error: Error) {
        parseError = parseError ?? error
    }
}

// MARK: - ValidationDelegate

private final class ValidationDelegate: NSObject, Foundation.XMLParserDelegate {

    var issues: [ValidationIssue] = []

    func parser(_ parser: Foundation.XMLParser, parseErrorOccurred error: Error) {
        issues.append(ValidationIssue(
            severity: .error,
            message: error.localizedDescription,
            byteOffset: UInt64(max(0, parser.lineNumber))
        ))
    }

    func parser(_ parser: Foundation.XMLParser, validationErrorOccurred error: Error) {
        issues.append(ValidationIssue(
            severity: .warning,
            message: error.localizedDescription,
            byteOffset: UInt64(max(0, parser.lineNumber))
        ))
    }
}

// MARK: - Errors

public enum XMLParserError: Error, Sendable {
    case parseFailed
    case cannotSerializeContainer
    case noValueToSerialize
}
