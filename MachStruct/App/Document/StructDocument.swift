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

    /// Retained for files ≥ `lazyThreshold` so children can be materialised
    /// on demand without a full `buildNodeIndex()` at open time.
    /// Set to `nil` once the document is fully materialised.
    var structuralIndex: StructuralIndex?

    /// Files ≥ this size use lazy NodeIndex materialisation.
    private static let lazyThreshold: UInt64 = 5 * 1024 * 1024  // 5 MB

    // MARK: - Tabular heuristic

    /// True when the document looks tabular. Works for both lazy and fully-built indexes.
    var isTabular: Bool {
        if let si = structuralIndex { return si.looksTabular() }
        return nodeIndex?.isTabular() ?? false
    }

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
            let ext = (fileName as NSString).pathExtension.lowercased()

            // Run all heavy work on a background thread so the main actor stays
            // responsive during the load.  Three operations were previously blocking
            // the main actor and causing watchdog kills on large files:
            //   1. data.write(to:)    — synchronous disk write (up to tens of MB)
            //   2. parser.buildIndex  — structural parse (simdjson / Foundation)
            //   3. si.buildNodeIndex  — O(n) DocumentNode tree construction
            struct LoadResult: Sendable {
                let file: MappedFile
                let nodeIndex: NodeIndex
                let structuralIndex: StructuralIndex?  // non-nil for lazy (large) files
                let formatName: String
            }

            let result: LoadResult = try await Task.detached(priority: .userInitiated) {
                // 1. Write to a temp file so we can mmap it.
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).\(ext.isEmpty ? "dat" : ext)")
                try data.write(to: tmp)
                let file = try MappedFile(url: tmp)
                try? FileManager.default.removeItem(at: tmp)    // unlink is safe post-mmap

                // 2. Detect format and parse structural index (Phase 1).
                //    mmap is opened with MADV_SEQUENTIAL (set by MappedFile.init).
                let detected = FormatDetector.detect(file: file,
                                                     fileExtension: ext.isEmpty ? nil : ext)
                let si: StructuralIndex
                let name: String
                switch detected {
                case .json, .unknown:
                    si = try await JSONParser().buildIndex(from: file); name = "JSON"
                case .xml:
                    si = try await XMLParser().buildIndex(from: file);  name = "XML"
                case .yaml:
                    si = try await YAMLParser().buildIndex(from: file); name = "YAML"
                case .csv:
                    si = try await CSVParser().buildIndex(from: file);  name = "CSV"
                }

                // Phase 1 complete — switch mmap advice from sequential to random.
                // Phase 2 value parsing jumps to arbitrary byte offsets, so MADV_RANDOM
                // tells the OS to stop read-ahead and page only what's actually needed.
                file.adviseRandom()

                // 3. Build the node index.
                //
                //    Large files (≥ lazyThreshold): build a *shallow* NodeIndex containing
                //    only the root and its immediate visible children.  This is O(visible)
                //    instead of O(all_nodes), cutting memory by 90–99% and eliminating the
                //    hundreds-of-MB allocation that caused the rainbow spinner on 30 MB files.
                //    Deeper nodes are materialised on demand when the user expands them.
                //
                //    Small files: keep the existing eager full build.
                let useLazy = file.fileSize >= StructDocument.lazyThreshold
                if useLazy {
                    var idx = si.buildShallowNodeIndex()
                    // Post-parse keys/values for the initially-visible nodes.
                    // On the simdjson path, IndexEntry.key and parsedValue are nil; we need
                    // one Phase-2 parse per visible node to populate them so the tree renders.
                    StructDocument.parseVisibleEntries(in: &idx, structuralIndex: si, file: file)
                    return LoadResult(file: file, nodeIndex: idx,
                                      structuralIndex: si, formatName: name)
                } else {
                    return LoadResult(file: file, nodeIndex: si.buildNodeIndex(),
                                      structuralIndex: nil, formatName: name)
                }
            }.value

            mappedFile      = result.file
            nodeIndex       = result.nodeIndex
            structuralIndex = result.structuralIndex
            formatName      = result.formatName
        } catch {
            loadError = error
        }
        isLoading = false
    }

    // MARK: - Lazy materialisation

    /// Materialise the children of `nodeID` into `nodeIndex` if they are not yet present.
    ///
    /// Runs the heavy work (DocumentNode creation + Phase-2 key/value parsing) on a
    /// background thread so the main actor stays responsive even when expanding nodes
    /// with thousands of children.
    @MainActor
    func materializeChildrenIfNeeded(of nodeID: NodeID) async {
        guard let si = structuralIndex,
              let file = mappedFile,
              let childIdxs = si.childIndices[nodeID],
              !childIdxs.isEmpty else { return }
        guard var idx = nodeIndex else { return }

        // Skip if the first child is already in the index.
        let firstChildID = si.entries[childIdxs[0]].id
        guard idx.node(for: firstChildID) == nil else { return }

        // Build DocumentNode updates on a background thread.
        let updates = await Task.detached(priority: .userInitiated) { [si, file] in
            StructDocument.buildChildUpdates(for: nodeID, childIdxs: childIdxs,
                                              structuralIndex: si, file: file)
        }.value

        guard !updates.isEmpty else { return }
        idx.applySnapshot(updates)
        nodeIndex = idx
    }

    /// Ensure every node in the structural index is materialised in `nodeIndex`.
    ///
    /// Called before search so `SearchEngine` can traverse the full document.
    /// No-op when already fully materialised or no structural index is present.
    @MainActor
    func ensureFullyMaterialized() async {
        guard let si = structuralIndex, let file = mappedFile else { return }
        guard let current = nodeIndex, current.count < si.count else { return }

        let full = await Task.detached(priority: .userInitiated) { [si, file] in
            var idx = si.buildNodeIndex()
            // Parse keys/values for all nodes (simdjson path has nil key/parsedValue).
            StructDocument.parseAllEntries(in: &idx, structuralIndex: si, file: file)
            return idx
        }.value

        nodeIndex       = full
        structuralIndex = nil   // no longer needed
    }

    // MARK: - Phase-2 parse helpers (static, called from background tasks)

    /// Build `DocumentNode` updates for the children of `nodeID` and, for keyValue
    /// children, their value grandchildren too (needed for correct display).
    private static func buildChildUpdates(for nodeID: NodeID,
                                           childIdxs: [Int],
                                           structuralIndex si: StructuralIndex,
                                           file: MappedFile) -> [NodeID: DocumentNode] {
        var result = [NodeID: DocumentNode]()
        result.reserveCapacity(childIdxs.count * 2)

        for idx in childIdxs {
            let entry = si.entries[idx]
            let childIDs = (si.childIndices[entry.id] ?? []).map { si.entries[$0].id }
            let key   = entry.key   ?? parseKeyBytes(entry: entry, from: file)
            let value = entry.parsedValue.map { NodeValue.scalar($0) }
                        ?? parseValueBytes(entry: entry, from: file)
            result[entry.id] = DocumentNode(
                id: entry.id, type: entry.nodeType, depth: entry.depth,
                parentID: entry.parentID, childIDs: childIDs,
                key: key, value: value,
                sourceRange: SourceRange(byteOffset: entry.byteOffset,
                                         byteLength: entry.byteLength),
                metadata: entry.metadata
            )

            // For keyValue nodes, also materialise the value child so display works.
            if entry.nodeType == .keyValue,
               let valIdxs = si.childIndices[entry.id] {
                for vi in valIdxs {
                    let ve = si.entries[vi]
                    let gcChildIDs = (si.childIndices[ve.id] ?? []).map { si.entries[$0].id }
                    let veValue = ve.parsedValue.map { NodeValue.scalar($0) }
                                  ?? parseValueBytes(entry: ve, from: file)
                    result[ve.id] = DocumentNode(
                        id: ve.id, type: ve.nodeType, depth: ve.depth,
                        parentID: ve.parentID, childIDs: gcChildIDs,
                        key: ve.key, value: veValue,
                        sourceRange: SourceRange(byteOffset: ve.byteOffset,
                                                 byteLength: ve.byteLength),
                        metadata: ve.metadata
                    )
                }
            }
        }
        return result
    }

    /// Post-parse keys and values for every node already in `idx`.
    /// Called after `buildShallowNodeIndex` (for initially-visible nodes)
    /// and after `buildNodeIndex` (for the full-materialise-for-search path).
    private static func parseVisibleEntries(in idx: inout NodeIndex,
                                             structuralIndex si: StructuralIndex,
                                             file: MappedFile) {
        // Collect IDs that need key or value parsing.
        var updates = [NodeID: DocumentNode]()
        for entry in si.entries {
            guard var node = idx.node(for: entry.id) else { continue }
            var changed = false

            if node.key == nil, entry.nodeType == .keyValue {
                node.key = parseKeyBytes(entry: entry, from: file)
                changed = true
            }
            if case .unparsed = node.value, entry.nodeType == .scalar {
                node.value = parseValueBytes(entry: entry, from: file)
                changed = true
            }
            if changed { updates[node.id] = node }
        }
        if !updates.isEmpty { idx.applySnapshot(updates) }
    }

    /// Post-parse keys and values for ALL entries (used after full buildNodeIndex).
    private static func parseAllEntries(in idx: inout NodeIndex,
                                         structuralIndex si: StructuralIndex,
                                         file: MappedFile) {
        var updates = [NodeID: DocumentNode]()
        for entry in si.entries {
            guard var node = idx.node(for: entry.id) else { continue }
            var changed = false
            if node.key == nil, entry.nodeType == .keyValue {
                node.key = parseKeyBytes(entry: entry, from: file)
                changed = true
            }
            if case .unparsed = node.value, entry.nodeType == .scalar {
                node.value = parseValueBytes(entry: entry, from: file)
                changed = true
            }
            if changed { updates[node.id] = node }
        }
        if !updates.isEmpty { idx.applySnapshot(updates) }
    }

    /// Parse the JSON key string for a `.keyValue` entry (simdjson path).
    /// On the simdjson path, the key is stored as a quoted JSON string at `byteOffset`.
    private static func parseKeyBytes(entry: IndexEntry, from file: MappedFile) -> String? {
        guard entry.byteLength > 0,
              let raw = try? file.data(offset: entry.byteOffset, length: entry.byteLength),
              let str = try? JSONSerialization.jsonObject(with: raw,
                                                          options: .allowFragments) as? String
        else { return nil }
        return str
    }

    /// Parse the JSON value for a `.scalar` entry (simdjson path).
    private static func parseValueBytes(entry: IndexEntry, from file: MappedFile) -> NodeValue {
        guard entry.nodeType == .scalar, entry.byteLength > 0,
              let raw = try? file.data(offset: entry.byteOffset, length: entry.byteLength),
              let any = try? JSONSerialization.jsonObject(with: raw,
                                                          options: .allowFragments)
        else { return .unparsed }
        return .scalar(scalarFromAny(any))
    }

    /// Mirror of `JSONParser.scalarValue(from:)` without requiring the actor.
    private static func scalarFromAny(_ any: Any) -> ScalarValue {
        if let b = any as? Bool { return .boolean(b) }
        if let n = any as? NSNumber,
           CFGetTypeID(n as CFTypeRef) != CFBooleanGetTypeID() {
            if n.doubleValue.truncatingRemainder(dividingBy: 1) == 0,
               n.doubleValue >= Double(Int64.min),
               n.doubleValue <= Double(Int64.max) {
                return .integer(n.int64Value)
            }
            return .float(n.doubleValue)
        }
        if let s = any as? String { return .string(s) }
        if any is NSNull { return .null }
        return .string(String(describing: any))
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
