import Foundation

// MARK: - FormatConverter

/// Stateless utility for converting a parsed `NodeIndex` to a different format.
///
/// ```swift
/// let data = try FormatConverter().convert(index: nodeIndex, to: .yaml)
/// ```
///
/// **Supported conversions:**
///
/// | Source → Target | JSON | YAML | CSV |
/// |-----------------|:----:|:----:|:---:|
/// | Any document    |  ✅  |  ✅  |  ❌ |
/// | Tabular only    |  —   |  —   |  ✅ |
///
/// CSV export requires the document to satisfy `NodeIndex.isTabular()`.
/// Use `canConvert(index:to:)` to check before calling `convert`.
public struct FormatConverter: Sendable {

    // MARK: - Target format

    /// The output format for a conversion.
    public enum TargetFormat: String, CaseIterable, Sendable {
        case json = "JSON"
        case yaml = "YAML"
        case csv  = "CSV"

        /// Canonical file-name extension for this format.
        public var fileExtension: String {
            switch self {
            case .json: return "json"
            case .yaml: return "yaml"
            case .csv:  return "csv"
            }
        }

        /// MIME type for the format (for use in share sheets / HTTP responses).
        public var mimeType: String {
            switch self {
            case .json: return "application/json"
            case .yaml: return "application/yaml"
            case .csv:  return "text/csv"
            }
        }
    }

    public init() {}

    // MARK: - Public API

    /// Convert `index` to the requested `format`.
    ///
    /// - Parameters:
    ///   - index:      The parsed document to convert.
    ///   - mappedFile: Optional mapped source file.  Required for accurate JSON
    ///                 output when the source was parsed with simdjson (which
    ///                 leaves `.unparsed` scalars in the index).  Not needed for
    ///                 YAML or CSV output.
    ///   - format:     The desired output format.
    /// - Throws: `CSVSerializerError.notTabular` when converting to CSV a
    ///   document that is not a uniform array of objects.
    public func convert(
        index: NodeIndex,
        mappedFile: MappedFile? = nil,
        to format: TargetFormat
    ) throws -> Data {
        switch format {
        case .json:
            return try JSONDocumentSerializer(index: index, mappedFile: mappedFile)
                .serialize(pretty: true)
        case .yaml:
            return try YAMLDocumentSerializer(index: index).serialize()
        case .csv:
            return try CSVDocumentSerializer(index: index).serialize()
        }
    }

    /// Returns `true` if `index` can be converted to `format`.
    ///
    /// JSON and YAML accept any document; CSV requires `isTabular()`.
    public func canConvert(index: NodeIndex, to format: TargetFormat) -> Bool {
        switch format {
        case .json, .yaml: return true
        case .csv:         return index.isTabular()
        }
    }
}
