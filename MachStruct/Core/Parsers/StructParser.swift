import Foundation

/// Protocol every format parser must implement.
/// The sole extension point for adding XML, YAML, CSV, and future formats.
///
/// Full protocol design (buildIndex / parseValue / serialize / validate) in P1-05.
/// This stub defines the minimal shape required by P1-04 tests.
public protocol StructParser: Sendable {
    /// File extensions this parser handles (lowercase, no leading dot — e.g. `"json"`).
    static var supportedExtensions: Set<String> { get }

    /// Build a structural index from the source file.
    /// Must be fast: structural boundaries only, no value parsing.
    func buildIndex(from file: MappedFile) async throws -> NodeIndex

    /// Parse the value of a single node on demand (lazy, Phase 2).
    func parseValue(at range: SourceRange, from file: MappedFile) throws -> NodeValue

    /// Serialize a modified node value back to the format's text representation.
    func serialize(value: NodeValue) throws -> Data
}

/// Maps file extensions to registered parser instances.
/// Full implementation in P1-05.
public actor ParserRegistry {
    public static let shared = ParserRegistry()

    private var parsers: [String: any StructParser] = [:]

    private init() {}

    public func register(_ parser: any StructParser) {
        for ext in type(of: parser).supportedExtensions {
            parsers[ext.lowercased()] = parser
        }
    }

    public func parser(for fileExtension: String) -> (any StructParser)? {
        parsers[fileExtension.lowercased()]
    }
}
