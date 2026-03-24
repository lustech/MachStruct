import SwiftUI
import UniformTypeIdentifiers
import MachStructCore

// MARK: - StructDocument

/// Reference-type document model for the SwiftUI `DocumentGroup` scene.
///
/// On open, the file is written to a private temporary location so it can be
/// memory-mapped even though the `DocumentGroup` protocol delivers content as
/// `FileWrapper` data rather than a file URL.  Parsing runs asynchronously on
/// a detached task so the UI thread is never blocked.
final class StructDocument: ReferenceFileDocument {

    // MARK: - DocumentGroup protocol

    static var readableContentTypes: [UTType] { [.json] }

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

    // MARK: - Empty document (new file — read-only for Phase 1)

    init() {}

    // MARK: - Snapshot / write (read-only in Phase 1)

    func snapshot(contentType: UTType) throws -> Void {}

    func fileWrapper(snapshot: Void, configuration: WriteConfiguration) throws -> FileWrapper {
        // Phase 1 is view-only.  Saving is disabled.
        throw StructDocumentError.readOnly
    }

    // MARK: - Async load

    @MainActor
    private func load(data: Data) async {
        isLoading = true
        loadError = nil
        do {
            // Write to a temp file so we can mmap it.  The file is unlinked after
            // mmap so the directory entry disappears while the pages remain accessible.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).json")
            try data.write(to: tmp)
            let file = try MappedFile(url: tmp)
            try? FileManager.default.removeItem(at: tmp)    // unlink is safe post-mmap

            let si = try await JSONParser().buildIndex(from: file)
            nodeIndex = si.buildNodeIndex()
        } catch {
            loadError = error
        }
        isLoading = false
    }
}

// MARK: - Errors

enum StructDocumentError: LocalizedError {
    case noFileContent
    case readOnly

    var errorDescription: String? {
        switch self {
        case .noFileContent: return "The file could not be read."
        case .readOnly:      return "MachStruct is view-only in this version."
        }
    }
}
