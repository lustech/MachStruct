import Foundation
@testable import MachStructCore

// How `XMLParser` indexed a file before `XMLSource`, kept as the reference
// its nodes are compared against.

// MARK: - ReferenceSAXBuilder

/// Accumulates `IndexEntry` values from `Foundation.XMLParser` SAX callbacks.
///
/// Uses a mutable `BuildEntry` intermediate (value type, mutated in place via array
/// index access) so that `childCount` and `isSelfClosing` can be finalised in
/// `didEndElement` after the entry was appended in `didStartElement`.
final class ReferenceSAXBuilder: NSObject, Foundation.XMLParserDelegate {

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
