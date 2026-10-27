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
    /// Set for large files, whose `index` holds only the nodes materialised so
    /// far. JSON copies the rest from `mappedFile`; other formats rebuild the
    /// whole document from it (`StructDocument.completeIndex`).
    let structuralIndex: StructuralIndex?
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

    /// Formats `fileWrapper` can write. XML has no serializer, so it is left
    /// out and an XML document cannot be saved in place (#39).
    static var writableContentTypes: [UTType] {
        readableContentTypes.filter { $0 != .xml && $0 != .data }
    }

    private static let yamlTypes: [UTType] = ["yaml", "yml"].compactMap {
        UTType(filenameExtension: $0)
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

    /// Set when the JSON auto-fixer was used to recover this document (B3).
    /// Nil for normal parses; populated with the fixes that were applied so
    /// the UI can show a banner explaining what changed.
    @Published var autoFixApplied: Set<JSONAutoFixer.Fix>? = nil

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

    /// Every node an edit has touched. Eviction must keep them: an evicted
    /// node is rebuilt from the source file, which no longer matches.
    private var editedIDs = Set<NodeID>()

    /// Bumped by every edit, undo and redo, so a `WholeDocument` can tell it
    /// is out of date and the find bar can recount.
    @Published private(set) var editCount = 0

    /// The last `wholeDocument()` result, while it is current.
    private var wholeDocumentCache: WholeDocument?

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
        return DocumentSnapshot(index: idx, mappedFile: mappedFile,
                                structuralIndex: structuralIndex)
    }

    func fileWrapper(snapshot: DocumentSnapshot,
                     configuration: WriteConfiguration) throws -> FileWrapper {
        // Write the file back in its own format. This used to emit JSON
        // whatever the type, so saving a CSV or YAML file replaced it with
        // JSON (#39).
        let type = configuration.contentType
        let data: Data
        if type.conforms(to: .json) {
            data = try JSONDocumentSerializer(index: snapshot.index,
                                              mappedFile: snapshot.mappedFile)
                .serialize(pretty: true)
        } else if type.conforms(to: .commaSeparatedText) {
            data = try CSVDocumentSerializer(index: Self.completeIndex(of: snapshot))
                .serializeInSourceLayout()
        } else if Self.yamlTypes.contains(where: { type.conforms(to: $0) }) {
            // Patch the original text where possible: regenerating it drops
            // comments, anchors and quoting.
            let index = Self.completeIndex(of: snapshot)
            if let source = Self.sourceText(of: snapshot),
               let patched = YAMLSourcePatcher.patch(source: source, edited: index) {
                data = Data(patched.utf8)
            } else {
                data = try YAMLDocumentSerializer(index: index).serialize()
            }
        } else {
            throw StructDocumentError.unsupportedSaveFormat
        }
        return FileWrapper(regularFileWithContents: data)
    }

    /// The whole document with the user's edits applied.
    ///
    /// A large file's index holds only what has been expanded, and only the
    /// JSON serializer can fill the gaps from the source bytes. The others
    /// would write the unexpanded parts as empty.
    static func completeIndex(_ current: NodeIndex,
                              structuralIndex si: StructuralIndex?,
                              file: MappedFile?) -> NodeIndex {
        si?.completeNodeIndex(overlaying: current, file: file) ?? current
    }

    /// The file as it was opened, as UTF-8 text.
    private static func sourceText(of snapshot: DocumentSnapshot) -> String? {
        guard let file = snapshot.mappedFile, file.fileSize > 0, file.fileSize <= UInt64(UInt32.max),
              let data = try? file.data(offset: 0, length: UInt32(file.fileSize)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func completeIndex(of snapshot: DocumentSnapshot) -> NodeIndex {
        completeIndex(snapshot.index, structuralIndex: snapshot.structuralIndex,
                      file: snapshot.mappedFile)
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
        editedIDs.formUnion(tx.beforeSnapshot.keys)
        editedIDs.formUnion(tx.afterSnapshot.keys)
        editCount += 1

        // Register undo.  Calling commitEdit recursively from the undo handler
        // is safe because NSUndoManager automatically routes calls made inside
        // an undo operation onto the redo stack.
        undoManager?.registerUndo(withTarget: self) { [tx, weak undoManager] doc in
            doc.commitEdit(tx.reversed, undoManager: undoManager)
        }
        undoManager?.setActionName(tx.description)
    }

    // MARK: - Whole-document operations

    /// The whole document at a given edit, for operations that must see every
    /// node: Find & Replace and queries. `nodeIndex` holds only what has been
    /// expanded in a large file, so working on it misses the rest.
    struct WholeDocument {
        let index: NodeIndex
        fileprivate let editCount: Int
    }

    /// Builds the whole document in the background for a large file, and keeps
    /// it until the next edit or `releaseWholeDocument()`.
    @MainActor
    func wholeDocument() async -> WholeDocument? {
        while true {
            guard let current = nodeIndex else { return nil }
            guard let si = structuralIndex else {
                return WholeDocument(index: current, editCount: editCount)
            }
            if let cached = wholeDocumentCache, cached.editCount == editCount { return cached }
            let edits = editCount
            let file = mappedFile
            let full = await Task.detached(priority: .userInitiated) { [si, current, file] in
                si.completeNodeIndex(overlaying: current, file: file)
            }.value
            // An edit made meanwhile isn't in `full`: build again.
            guard edits == editCount else { continue }
            wholeDocumentCache = WholeDocument(index: full, editCount: edits)
            return wholeDocumentCache
        }
    }

    /// Free the whole document built by `wholeDocument()`.
    func releaseWholeDocument() {
        wholeDocumentCache = nil
    }

    /// Commit an edit computed on `base`, which may touch nodes that were
    /// never expanded. Returns `false`, changing nothing, if the document has
    /// been edited since `base` was built.
    ///
    /// The whole document becomes the index first, so those nodes arrive with
    /// their ancestors and siblings: saving JSON copies the original bytes of
    /// any container with a child missing, which would drop the edit.
    /// Eviction then trims it back, keeping the edits and what surrounds them.
    @MainActor
    @discardableResult
    func commitEdit(_ tx: EditTransaction, over base: WholeDocument,
                    undoManager: UndoManager?,
                    expandedIDs: Set<NodeID>, selectedID: NodeID?) -> Bool {
        guard base.editCount == editCount else { return false }
        guard structuralIndex != nil else {
            commitEdit(tx, undoManager: undoManager)
            return true
        }
        nodeIndex = base.index
        commitEdit(tx, undoManager: undoManager)
        if let full = nodeIndex {
            wholeDocumentCache = WholeDocument(index: full, editCount: editCount)
        }
        evictIfNeeded(expandedIDs: expandedIDs, selectedID: selectedID)
        return true
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
        await load(data: data, attemptAutoFix: true)
    }

    /// Internal load with control over whether to retry via `JSONAutoFixer`
    /// on parse failure.  The retry recurses with `attemptAutoFix: false` so
    /// a fixer-induced error never loops forever.
    @MainActor
    private func load(data: Data, attemptAutoFix: Bool) async {
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
                    case .nodesIndexed(let count):
                        indexedNodeCount += count

                    case .complete(let si):
                        // Phase 1 done — switch mmap advice to random-access for Phase 2.
                        file.adviseRandom()

                        // Build the shallow NodeIndex on a background thread (fast, O(visible)).
                        let (idx, retainedSI) = await Task.detached(priority: .userInitiated) {
                            [si, file] in
                            var idx = si.buildShallowNodeIndex()
                            si.parseUnparsedEntries(in: &idx, file: file)
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
            // B3 — JSON auto-fixer recovery: on JSON parse failure, run the
            // fixer once and retry.  Other formats fall straight through to
            // the error path.
            if attemptAutoFix, formatName == "JSON" {
                let result = JSONAutoFixer.fix(data)
                if result.didChange {
                    isLoading = false
                    await load(data: result.fixed, attemptAutoFix: false)
                    if loadError == nil {
                        autoFixApplied = result.fixesApplied
                    } else {
                        // Report the file's own error: the retry's position
                        // refers to the fixer's output, not to the file.
                        loadError = error
                    }
                    return
                }
            }
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
        await materializeChildrenIfNeeded(of: [nodeID], expandedIDs: expandedIDs,
                                          selectedID: selectedID)
    }

    /// Materialise the children of each of `nodeIDs` in one background pass,
    /// for the rows the table view shows.
    @MainActor
    func materializeChildrenIfNeeded(of nodeIDs: [NodeID],
                                      expandedIDs: Set<NodeID> = [],
                                      selectedID: NodeID? = nil) async {
        guard let si = structuralIndex,
              let file = mappedFile,
              let current = nodeIndex else { return }
        // Rows drill through `.keyValue` nodes to their value, so the nodes a row
        // needs are the value's children — not the keyValue's direct child, which
        // `buildShallowNodeIndex` has already materialised. Probing that value
        // node made this method bail out every time (issue #23).
        // Skip only the nodes whose rows are already present.
        let pending: [(id: NodeID, childIdxs: [Int])] = nodeIDs.compactMap { id in
            let childIdxs = si.expansionTargets(for: id)
            guard let first = childIdxs.first,
                  current.node(for: si.entries[first].id) == nil else { return nil }
            return (id, childIdxs)
        }
        guard !pending.isEmpty else { return }

        // Build DocumentNode updates on a background thread.
        let updates = await Task.detached(priority: .userInitiated) { [si, file] in
            var all = [NodeID: DocumentNode]()
            for (id, childIdxs) in pending {
                all.merge(StructDocument.buildChildUpdates(for: id, childIdxs: childIdxs,
                                                           structuralIndex: si, file: file)) { a, _ in a }
            }
            return all
        }.value

        // Read the index only now: an edit committed during the build would
        // otherwise be overwritten. Nodes already present are kept as they
        // are — some of the siblings may hold edits.
        guard var idx = nodeIndex else { return }
        let missing = updates.filter { idx.node(for: $0.key) == nil }
        guard !missing.isEmpty else { return }
        idx.applySnapshot(missing)
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
    /// - Edited nodes, their ancestors and those ancestors' rows
    ///
    /// Everything else is removed from `nodeIndex`; it will be rebuilt lazily
    /// the next time the user expands that branch.
    @MainActor
    func evictIfNeeded(expandedIDs: Set<NodeID>, selectedID: NodeID?) {
        guard var idx = nodeIndex,
              idx.count > StructDocument.evictionThreshold,
              let si = structuralIndex else { return }

        var hot = Set<NodeID>()
        hot.reserveCapacity(expandedIDs.count * 20)

        // The hot set must follow what the tree actually renders, which drills
        // through `.keyValue` nodes. Deriving it from `childIDs` kept the value
        // node but neither the rows beneath it nor the value nodes those rows
        // need, so materialised children were evicted immediately and visible
        // rows lost their values (issue #23).

        // Root is always hot, along with the rows rendered directly beneath it.
        hot.insert(idx.rootID)
        hot.formUnion(si.visibleDescendantIDs(for: idx.rootID))

        // Expanded rows and the rows they reveal.
        for id in expandedIDs {
            hot.insert(id)
            hot.formUnion(si.visibleDescendantIDs(for: id))
        }

        // Keep the selected node (details panel / editing needs it).
        if let sel = selectedID { hot.insert(sel) }

        // Keep edits, and everything around them a save needs: the JSON
        // serializer copies a container's original bytes when any of its
        // children is missing, which would undo the edit.
        var keptAncestors: Set<NodeID> = [idx.rootID]
        for id in editedIDs where idx.node(for: id) != nil {
            hot.insert(id)
            var parent = idx.node(for: id)?.parentID
            while let p = parent, keptAncestors.insert(p).inserted {
                hot.insert(p)
                hot.formUnion(si.visibleDescendantIDs(for: p))
                parent = idx.node(for: p)?.parentID ?? si.entry(for: p)?.parentID
            }
        }

        let toEvict = Set(idx.allNodeIDs).subtracting(hot)
        guard !toEvict.isEmpty else { return }

        idx.evictNodes(toEvict)
        nodeIndex = idx
    }

    // MARK: - Phase-2 parse helpers (static, called from background tasks)

    /// Node value for a lazily-materialised entry.
    ///
    /// Mirrors `StructuralIndex.makeDocumentNode`, which is the canonical
    /// version: containers carry their child count, scalars are parsed from the
    /// mapped bytes, and keyValue nodes hold nothing themselves. Computing this
    /// as `parsedValue ?? parsedValue(of:in:)` silently produced `.unparsed`
    /// for objects and arrays, so every lazily-materialised container rendered
    /// as "{0 keys}" (issue #23).
    private static func nodeValue(for entry: IndexEntry,
                                   from file: MappedFile) -> NodeValue {
        switch entry.nodeType {
        case .object, .array:
            return .container(childCount: Int(entry.childCount))
        case .scalar:
            return entry.parsedValue.map { NodeValue.scalar($0) }
                   ?? StructuralIndex.parsedValue(of: entry, in: file)
        case .keyValue:
            return .unparsed
        }
    }

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
            let key   = si.keyTable.intern(entry.key ?? StructuralIndex.parsedKey(of: entry, in: file))
            let value = StructDocument.nodeValue(for: entry, from: file)
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
                    let veValue = StructDocument.nodeValue(for: ve, from: file)
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

}

// MARK: - Errors

enum StructDocumentError: LocalizedError {
    case noFileContent
    case noContent
    case unsupportedSaveFormat

    var errorDescription: String? {
        switch self {
        case .noFileContent: return "The file could not be read."
        case .noContent:     return "The document has no content to save."
        case .unsupportedSaveFormat:
            return "MachStruct can't save documents in this format."
        }
    }

    // NSDocument titles its save alert "The document … could not be saved."
    // and drops `errorDescription`; it shows the failure reason and recovery
    // suggestion underneath, so the explanation has to live there too.
    var failureReason: String? {
        switch self {
        case .noFileContent, .noContent: return nil
        case .unsupportedSaveFormat:
            return "MachStruct can't save documents in this format."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noFileContent, .noContent: return nil
        case .unsupportedSaveFormat:
            return "Use Export in the toolbar to save a copy in another format. The original file has not been changed."
        }
    }
}
