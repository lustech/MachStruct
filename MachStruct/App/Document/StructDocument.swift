import SwiftUI
import UniformTypeIdentifiers
import MachStructCore

// MARK: - DocumentSnapshot

/// A lightweight snapshot of the document for `ReferenceFileDocument`.
///
/// `NodeIndex` is a value type (COW) so capturing it is cheap.
/// `MappedFile` is reference-typed but safe to share across threads (`@unchecked Sendable`).
struct DocumentSnapshot: Sendable {
    let index: NodeIndex
    let mappedFile: MappedFile?
}

// MARK: - StructDocument

/// Reference-type document model for the SwiftUI `DocumentGroup` scene.
///
/// On open, the file is written to a private temporary location so it can be
/// memory-mapped even though the `DocumentGroup` protocol delivers content as
/// `FileWrapper` data rather than a file URL.  Parsing runs asynchronously on
/// a detached task so the UI thread is never blocked.
///
/// The `MappedFile` is kept alive as a stored property so that:
///   - Large-file (simdjson) scalar nodes with `.unparsed` value can be
///     re-parsed from source bytes when the document is saved (P2-06).
///   - The raw-text view (P2-09) can re-serialize the full document.
final class StructDocument: ReferenceFileDocument {

    // MARK: - DocumentGroup protocol

    static var readableContentTypes: [UTType] {
        [
            .json,
            .xml,
            .commaSeparatedText,
            UTType(filenameExtension: "yaml") ?? .data,
            UTType(filenameExtension: "yml")  ?? .data,
        ]
    }

    // MARK: - Published state

    @Published var nodeIndex: NodeIndex?
    @Published var isLoading: Bool = false
    @Published var loadError: Error?

    /// Display name used in the window title (derived from the FileWrapper filename).
    @Published var fileName: String = "Untitled"

    /// Raw byte size of the opened file (set once loading completes).
    @Published var fileSize: Int64 = 0

    /// Human-readable format identifier shown in the status bar.
    var formatName: String = "JSON"

    // MARK: - Internal state

    /// Kept alive so unparsed scalar nodes can be re-read for save / raw view.
    var mappedFile: MappedFile?

    // MARK: - Init (called by DocumentGroup when a file is opened)

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw StructDocumentError.noFileContent
        }
        fileName = configuration.file.filename ?? "document.json"
        let byteCount = Int64(data.count)

        // Kick off async parsing without blocking the current call.
        Task { @MainActor [weak self] in
            self?.fileSize = byteCount
            await self?.load(data: data)
        }
    }

    // MARK: - Empty document (new file / placeholder)

    init() {}

    // MARK: - Snapshot / write (P2-06)

    func snapshot(contentType: UTType) throws -> DocumentSnapshot {
        guard let idx = nodeIndex else {
            throw StructDocumentError.noContent
        }
        return DocumentSnapshot(index: idx, mappedFile: mappedFile)
    }

    func fileWrapper(snapshot: DocumentSnapshot,
                     configuration: WriteConfiguration) throws -> FileWrapper {
        let serializer = JSONDocumentSerializer(index: snapshot.index,
                                                mappedFile: snapshot.mappedFile)
        let data = try serializer.serialize(pretty: true)
        return FileWrapper(regularFileWithContents: data)
    }

    // MARK: - Edit API (P2-05)

    /// Apply a transaction to the document and register it with the system
    /// `UndoManager` so that Cmd+Z / Cmd+Shift+Z work natively.
    ///
    /// - Parameters:
    ///   - tx:           The transaction describing the forward change.
    ///   - undoManager:  The window's undo manager, obtained from the SwiftUI
    ///                   environment via `@Environment(\.undoManager)`.
    @MainActor
    func commitEdit(_ tx: EditTransaction, undoManager: UndoManager?) {
        guard let current = nodeIndex else { return }
        nodeIndex = tx.applying(to: current)

        // Register undo.  Calling commitEdit recursively from the undo handler
        // is safe because NSUndoManager automatically routes calls made inside
        // an undo operation onto the redo stack.
        undoManager?.registerUndo(withTarget: self) { [tx, weak undoManager] doc in
            doc.commitEdit(tx.reversed, undoManager: undoManager)
        }
        undoManager?.setActionName(tx.description)
    }

    // MARK: - Serialization helper (P2-09 raw view, P2-08 copy)

    /// Serialize the subtree rooted at `nodeID` to JSON data.
    ///
    /// Returns `nil` if the node is not found or serialization fails.
    func serializeNode(_ nodeID: NodeID, pretty: Bool = true) -> Data? {
        guard let idx = nodeIndex else { return nil }
        return try? JSONDocumentSerializer(index: idx, mappedFile: mappedFile)
            .serialize(nodeID: nodeID, pretty: pretty)
    }

    /// Serialize the entire document to a UTF-8 JSON string.
    ///
    /// This is an `async` throwing function so that callers can dispatch it
    /// off the main thread for large documents.
    func serializeDocument(pretty: Bool = true) async throws -> String {
        guard let idx = nodeIndex else { return "{}" }
        let file = mappedFile
        return try await Task.detached(priority: .userInitiated) {
            let data = try JSONDocumentSerializer(index: idx, mappedFile: file)
                .serialize(pretty: pretty)
            return String(data: data, encoding: .utf8) ?? "{}"
        }.value
    }

    // MARK: - Async load

    @MainActor
    private func load(data: Data) async {
        isLoading = true
        loadError = nil
        do {
            // Derive the file extension so the detector can use it as a tiebreaker.
            let ext = (fileName as NSString).pathExtension.lowercased()

            // Write to a temp file so we can mmap it.  We keep the original
            // extension so madvise hints stay correct.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).\(ext.isEmpty ? "dat" : ext)")
            try data.write(to: tmp)
            let file = try MappedFile(url: tmp)
            try? FileManager.default.removeItem(at: tmp)    // unlink is safe post-mmap

            mappedFile = file   // Keep alive for save / Phase 2 value parsing.

            // ── Auto-detect format ──────────────────────────────────────────
            let detected = FormatDetector.detect(file: file,
                                                 fileExtension: ext.isEmpty ? nil : ext)
            let (si, name) = try await parseFile(file, detectedAs: detected)
            nodeIndex  = si.buildNodeIndex()
            formatName = name
        } catch {
            loadError = error
        }
        isLoading = false
    }

    // MARK: - Format dispatch

    /// Pick the right parser for `detected` and return the structural index +
    /// a human-readable format name for the status bar.
    private func parseFile(
        _ file: MappedFile,
        detectedAs detected: FormatDetector.DetectedFormat
    ) async throws -> (StructuralIndex, String) {
        switch detected {
        case .json, .unknown:
            return (try await JSONParser().buildIndex(from: file), "JSON")
        case .xml:
            return (try await XMLParser().buildIndex(from: file), "XML")
        case .yaml:
            return (try await YAMLParser().buildIndex(from: file), "YAML")
        case .csv:
            return (try await CSVParser().buildIndex(from: file), "CSV")
        }
    }
}

// MARK: - Errors

enum StructDocumentError: LocalizedError {
    case noFileContent
    case noContent

    var errorDescription: String? {
        switch self {
        case .noFileContent: return "The file could not be read."
        case .noContent:     return "The document has no content to save."
        }
    }
}
