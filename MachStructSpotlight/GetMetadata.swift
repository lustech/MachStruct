import Foundation
import CoreSpotlight

// MARK: - Spotlight Importer (P6-06)
//
// This file is compiled into the MachStructSpotlight.mdimporter bundle.
// macOS calls GetMetadataForFile() via the Spotlight index daemon whenever
// a JSON, XML, YAML, or CSV file changes on disk.
//
// We populate:
//   kMDItemTextContent   — full UTF-8 text (Spotlight full-text search)
//   kMDItemKind          — human-readable "JSON Document" etc.
//   kMDItemContentType   — UTI string
//   kMDItemContentTypeTree — UTI hierarchy
//
// The heavy lifting (parsing structured metadata) is deliberately omitted
// in v1 to keep the importer fast and crash-free.  The text content alone
// enables Spotlight to find any key name or string value.

/// Called by Spotlight's `mdimport` daemon for every matching file.
///
/// - Parameters:
///   - attributes: Mutable dictionary; populate with metadata keys.
///   - contentTypeUTI: UTI of the file being indexed.
///   - pathToFile: Absolute path of the file on disk.
/// - Returns: `true` on success, `false` on failure.
@_cdecl("GetMetadataForFile")
public func getMetadataForFile(
    _ attributes: NSMutableDictionary,
    contentType contentTypeUTI: NSString,
    forFile pathToFile: NSString
) -> Bool {
    let path = pathToFile as String
    let uti  = contentTypeUTI as String

    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8)
                  ?? String(data: data, encoding: .isoLatin1)
    else { return false }

    // Full-text content — enables key/value search from Spotlight.
    // Truncate to 1 MB to avoid filling the Spotlight store with huge files.
    let maxBytes = 1_048_576
    let truncated = data.count > maxBytes
        ? String(text.prefix(maxBytes))
        : text

    attributes[kMDItemTextContent as NSString] = truncated as NSString

    // Human-readable kind string (shown in Spotlight results).
    let kind: String
    switch uti {
    case "public.json":                          kind = "JSON Document"
    case "public.xml":                           kind = "XML Document"
    case "public.comma-separated-values-text":   kind = "CSV Document"
    case "public.yaml", "org.yaml.yaml":         kind = "YAML Document"
    default:                                     kind = "Structured Document"
    }
    attributes[kMDItemKind as NSString] = kind as NSString

    // Content type for filtering.
    attributes[kMDItemContentType as NSString] = uti as NSString

    return true
}
