import Foundation

// MARK: - JSONDocumentSerializer

/// Serializes a `NodeIndex` to JSON `Data`.
///
/// Walks the node tree recursively, converting each node to its Foundation
/// `Any` equivalent and calling `JSONSerialization` at the end.
///
/// **Unparsed nodes**: Large files (≥ 5 MB) parsed via simdjson leave scalar
/// nodes with `.unparsed` value.  If a `MappedFile` is provided, unparsed
/// scalars are re-read directly from the source bytes at their stored
/// `sourceRange` offsets.  Without a mapped file they serialize as `null`.
public struct JSONDocumentSerializer {

    private let index: NodeIndex
    private let mappedFile: MappedFile?

    public init(index: NodeIndex, mappedFile: MappedFile? = nil) {
        self.index = index
        self.mappedFile = mappedFile
    }

    // MARK: - Public API

    /// Serialize the entire document to JSON bytes.
    ///
    /// A trailing newline is appended so files match the convention used by
    /// most editors.
    public func serialize(pretty: Bool = true) throws -> Data {
        guard let root = index.root else {
            throw JSONSerializerError.emptyDocument
        }
        let obj = try buildAny(for: root)
        let data = try jsonData(obj, pretty: pretty)
        return data + Data("\n".utf8)
    }

    /// Serialize the subtree rooted at a specific node.
    ///
    /// Useful for copying a single node to the clipboard.
    public func serialize(nodeID: NodeID, pretty: Bool = true) throws -> Data {
        guard let node = index.node(for: nodeID) else {
            throw JSONSerializerError.nodeNotFound
        }
        // For keyValue nodes expose the value child directly.
        let target = (node.type == .keyValue)
            ? (index.children(of: node.id).first ?? node)
            : node
        let obj = try buildAny(for: target)
        return try jsonData(obj, pretty: pretty)
    }

    // MARK: - Private tree walk

    private func buildAny(for node: DocumentNode) throws -> Any {
        switch node.type {
        case .object:
            var dict = [String: Any]()
            for child in index.children(of: node.id) {
                guard child.type == .keyValue, let key = child.key else { continue }
                guard let valueChild = index.children(of: child.id).first else {
                    dict[key] = NSNull(); continue
                }
                dict[key] = try buildAny(for: valueChild)
            }
            return dict

        case .array:
            var arr = [Any]()
            for child in index.children(of: node.id) {
                arr.append(try buildAny(for: child))
            }
            return arr

        case .keyValue:
            // Reached when serializing a detached keyValue subtree.
            guard let valueChild = index.children(of: node.id).first else {
                return NSNull()
            }
            return try buildAny(for: valueChild)

        case .scalar:
            return try resolveScalar(node)
        }
    }

    private func resolveScalar(_ node: DocumentNode) throws -> Any {
        switch node.value {
        case .scalar(let sv):
            return anyValue(from: sv)

        case .unparsed:
            // Re-parse from source bytes when a MappedFile is available.
            guard let file = mappedFile, node.sourceRange.byteLength > 0 else {
                return NSNull()
            }
            let raw = try file.data(offset: node.sourceRange.byteOffset,
                                    length: node.sourceRange.byteLength)
            return try JSONSerialization.jsonObject(with: raw, options: [.allowFragments])

        case .container, .error:
            return NSNull()
        }
    }

    private func anyValue(from sv: ScalarValue) -> Any {
        switch sv {
        case .string(let s):  return s
        case .integer(let i): return NSNumber(value: i)
        case .float(let f):   return NSNumber(value: f)
        case .boolean(let b): return NSNumber(value: b)
        case .null:           return NSNull()
        }
    }

    private func jsonData(_ obj: Any, pretty: Bool) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed]
        if pretty { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: obj, options: options)
    }
}

// MARK: - Errors

public enum JSONSerializerError: Error, Sendable {
    /// The NodeIndex contains no root node.
    case emptyDocument
    /// The requested NodeID was not found in the index.
    case nodeNotFound
}
