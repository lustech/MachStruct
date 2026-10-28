import Foundation

// MARK: - XMLParser

/// SAX-based XML parser using Foundation.XMLParser (libxml2 under the hood).
///
/// **Phase 1** — `buildIndex(from:)`:
///   Streams SAX callbacks into `XMLSource`'s records, and lists them as a
///   flat `IndexEntry` array in document order.
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
        StructuralIndex(entries: try XMLSource(file: file).indexEntries())
    }

    // MARK: - Progressive streaming

    public nonisolated func parseProgressively(file: MappedFile) -> AsyncStream<ParseProgress> {
        ParseProgress.stream { try await XMLParser().buildIndex(from: file) }
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

extension XMLParser {

    /// libxml2's error, restated as a `ParseError`. Its message is already in
    /// XML terms ("Opening and ending tag mismatch: b line 2 and a"); the
    /// domain and code ("NSXMLParserErrorDomain error 76") are dropped.
    static func parseError(from error: Error?, in data: Data) -> ParseError {
        let info = (error as NSError?)?.userInfo ?? [:]
        let problem = (info["NSXMLParserErrorMessage"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "The file isn't well-formed XML"
        guard let line = info["NSXMLParserErrorLineNumber"] as? Int,
              let column = info["NSXMLParserErrorColumn"] as? Int, line > 0 else {
            return ParseError(problem: problem)
        }
        return data.withUnsafeBytes {
            ParseError(problem: problem, line: line, column: max(column, 1), in: $0)
        }
    }
}

public enum XMLParserError: Error, Sendable {
    case parseFailed
    case cannotSerializeContainer
    case noValueToSerialize
}
