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

    /// Running count of nodes emitted by `parseProgressively` during load.
    /// Resets to 0 at the start of each load; stays at the final node count
    /// once loading completes.  Used by the loading UI to show parse progress.
    @Published var indexedNodeCount: Int = 0

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

    /// When materialised node count exceeds this, evict cold nodes.
    private static let evictionThreshold: Int = 50_000

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
        indexedNodeCount = 0
        loadError = nil

        let ext = (fileName as NSString).pathExtension.lowercased()

        do {
            // Step 1 — write to a temp file so we can mmap it, then detect format.
            // Runs on a background thread; everything else follows from the stream.
            struct FileSetup: Sendable {
                let file: MappedFile
                let detected: FormatDetector.DetectedFormat
            }
            let setup: FileSetup = try await Task.detached(priority: .userInitiated) {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).\(ext.isEmpty ? "dat" : ext)")
                try data.write(to: tmp)
                let file = try MappedFile(url: tmp)
                try? FileManager.default.removeItem(at: tmp)   // safe to unlink post-mmap
                let detected = FormatDetector.detect(file: file,
                                                     fileExtension: ext.isEmpty ? nil : ext)
                return FileSetup(file: file, detected: detected)
            }.value

            let file = setup.file
            mappedFile = file

            // Step 2 — pick the right parser and record the format name.
            let parser: any StructParser
            switch setup.detected {
            case .json, .unknown: parser = JSONParser(); formatName = "JSON"
            case .xml:            parser = XMLParser();  formatName = "XML"
            case .yaml:           parser = YAMLParser(); formatName = "YAML"
            case .csv:            parser = CSVParser();  formatName = "CSV"
            }

            let useLazy = file.fileSize >= StructDocument.lazyThreshold

            if useLazy {
                // Step 3a — Large file: consume the progressive stream so the loading
                // UI can show a live node count while the parse runs in the background.
                //
                // Each `.nodesIndexed` batch bumps `indexedNodeCount` on the main actor,
                // giving the user animated feedback ("N nodes indexed") instead of a
                // static spinner.  On `.complete` we build the shallow NodeIndex so the
                // tree becomes visible as quickly as possible.
                for await progress in parser.parseProgressively(file: file) {
                    switch progress {
                    case .nodesIndexed(let batch):
                        indexedNodeCount += batch.count

                    case .complete(let si):
                        // Phase 1 done — switch mmap advice to random-access for Phase 2.
                        file.adviseRandom()

                        // Build the shallow NodeIndex on a background thread (fast, O(visible)).
                        let (idx, retainedSI) = await Task.detached(priority: .userInitiated) {
                            [si, file] in
                            var idx = si.buildShallowNodeIndex()
                            StructDocument.parseVisibleEntries(in: &idx,
                                                               structuralIndex: si, file: file)
                            return (idx, si)
                        }.value

                        nodeIndex       = idx
                        structuralIndex = retainedSI
                        indexedNodeCount = si.count   // snap to exact final count

                    case .warning:
                        break   // non-fatal — logged by parser internally

                    case .error(let err):
                        throw err
                    }
                }

            } else {
                // Step 3b — Small file: eager full build (same as before, no streaming needed).
                let si = try await parser.buildIndex(from: file)
                file.adviseRandom()
                let idx = await Task.detached(priority: .userInitiated) {
                    si.buildNodeIndex()
                }.value
                nodeIndex        = idx
                structuralIndex  = nil
                indexedNodeCount = idx.count
            }

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
    ///
    /// After materialising, evicts cold nodes if the index has grown past
    /// `evictionThreshold`.  Pass the current `expandedIDs` and `selectedID` so
    /// the eviction knows which nodes to keep.
    @MainActor
    func materializeChildrenIfNeeded(of nodeID: NodeID,
                                      expandedIDs: Set<NodeID> = [],
                                      selectedID: NodeID? = nil) async {
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

        // Evict cold nodes if we've grown past the threshold.
        evictIfNeeded(expandedIDs: expandedIDs, selectedID: selectedID)
    }

    /// Evict materialised nodes that are not part of the currently visible tree.
    ///
    /// Only runs when `nodeIndex.count > evictionThreshold` and a `structuralIndex`
    /// is present (so evicted nodes can be re-materialised on demand).
    ///
    /// Hot set (always kept):
    /// - Root node and its direct children (always rendered)
    /// - Every node in `expandedIDs` (rendered as rows)
    /// - Direct children of every expanded node (rendered as sub-rows)
    /// - `selectedID` if set (keeps details panel from going stale)
    ///
    /// Everything else is removed from `nodeIndex`; it will be rebuilt lazily
    /// the next time the user expands that branch.
    @MainActor
    func evictIfNeeded(expandedIDs: Set<NodeID>, selectedID: NodeID?) {
        guard var idx = nodeIndex,
              idx.count > StructDocument.evictionThreshold,
              structuralIndex != nil else { return }

        var hot = Set<NodeID>()
        hot.reserveCapacity(expandedIDs.count * 20)

        // Root is always hot.
        hot.insert(idx.rootID)

        // Root's direct children are always visible.
        if let root = idx.node(for: idx.rootID) {
            hot.formUnion(root.childIDs)
        }

        // Expanded nodes and their immediate children.
        for id in expandedIDs {
            hot.insert(id)
            if let node = idx.node(for: id) {
                hot.formUnion(node.childIDs)
            }
        }

        // Keep the selected node (details panel / editing needs it).
        if let sel = selectedID { hot.insert(sel) }

        let toEvict = Set(idx.allNodeIDs).subtracting(hot)
        guard !toEvict.isEmpty else { return }

        idx.evictNodes(toEvict)
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
            // Intern the key through the shared table so that repeated keys across
            // sibling objects share the same String backing storage.
            let key   = si.keyTable.intern(entry.key ?? parseKeyBytes(entry: entry, from: file))
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
        var updates = [NodeID: DocumentNode]()
        for entry in si.entries {
            guard var node = idx.node(for: entry.id) else { continue }
            var changed = false

            if node.key == nil, entry.nodeType == .keyValue {
                node.key = si.keyTable.intern(parseKeyBytes(entry: entry, from: file))
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
                node.key = si.keyTable.intern(parseKeyBytes(entry: entry, from: file))
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
