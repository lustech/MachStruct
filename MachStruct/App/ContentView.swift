import SwiftUI
import UniformTypeIdentifiers
import MachStructCore

// MARK: - ViewMode

/// The three mutually-exclusive content views for a document window.
enum ViewMode: Equatable {
    case tree   // expandable outline (default)
    case table  // spreadsheet grid (tabular documents only)
    case raw    // read-only serialized text
}

// MARK: - ContentView

/// Root content view for a single document window.
///
/// Delegates to one of three sub-views once the document has been parsed:
///   - **Tree view** — the default expandable outline (`TreeView`).
///   - **Table view** — available when the document is tabular; shows a
///     spreadsheet grid (`TableView`).  Enabled by the ⊞ toolbar button.
///   - **Raw view** — read-only serialized text (P2-09).  Enabled by the
///     `{ }` toolbar button; text is serialized asynchronously.
struct ContentView: View {

    @ObservedObject var document: StructDocument

    /// Lifted here so StatusBar can observe selection changes.
    @State private var selectedNodeID: NodeID?

    /// Active content mode (tree / table / raw).
    @State private var viewMode: ViewMode = .tree

    /// Buffered raw text.  Populated asynchronously when switching to `.raw`
    /// so the main thread is never blocked.
    @State private var rawText: String = ""

    /// True while raw text is being serialized in the background.
    @State private var isSerializingRaw: Bool = false

    /// True while an export conversion is running in the background.
    @State private var isExporting: Bool = false

    /// Export error to display in an alert.
    @State private var exportError: String? = nil

    // MARK: - Search state (P4-01)

    /// The live search query bound to the `.searchable` modifier.
    @State private var searchQuery: String = ""

    /// All matches for the current query, in document order.
    @State private var searchMatches: [SearchMatch] = []

    /// Index into `searchMatches` of the currently focused (active) match.
    @State private var activeMatchIndex: Int = 0

    /// Background search task — cancelled when the query changes.
    @State private var searchTask: Task<Void, Never>? = nil

    // MARK: - Tree expansion state (P4-02)

    /// Node IDs whose children are currently visible in the tree.
    ///
    /// Owned here (not inside `ExpandedTreeView`) so `expandPath(to:in:)` can
    /// programmatically open collapsed subtrees when navigating search matches.
    @State private var expandedIDs: Set<NodeID> = []

    /// Monotonically increasing counter — bumped each time we want
    /// `ExpandedTreeView` to scroll a row into view.  A counter (rather than
    /// the target ID alone) ensures the scroll fires even when navigating back
    /// to a previously-visited match with the same ID.
    @State private var scrollTrigger: Int = 0

    /// The node to scroll to when `scrollTrigger` increments.
    @State private var scrollTarget: NodeID? = nil

    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if document.isLoading {
                loadingView
            } else if let error = document.loadError {
                errorView(error)
            } else if let index = document.nodeIndex {
                contentStack(index)
                    .environment(\.commitEdit) { [weak document] tx in
                        document?.commitEdit(tx, undoManager: undoManager)
                    }
                    .environment(\.serializeNode) { [weak document] nodeID, pretty in
                        document?.serializeNode(nodeID, pretty: pretty)
                    }
                    .environment(\.searchMatchIDs,
                                  Set(searchMatches.map(\.rowNodeID)))
                    .environment(\.activeSearchMatchID,
                                  searchMatches.isEmpty ? nil
                                    : searchMatches[activeMatchIndex].rowNodeID)
                    .onChange(of: viewMode) { _, mode in
                        if mode == .raw { refreshRawText() }
                    }
                    .onChange(of: index.count) { _, _ in
                        if viewMode == .raw { refreshRawText() }
                    }
                    .onChange(of: searchQuery) { _, query in
                        scheduleSearch(query: query, in: index)
                    }
            } else {
                placeholderView
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .toolbar { toolbarContent }
        .searchable(text: $searchQuery,
                    placement: .toolbar,
                    prompt: "Search keys and values")
        .onSubmit(of: .search) { advanceMatch() }
        .alert("Export Failed", isPresented: .init(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Content stack

    @ViewBuilder
    private func contentStack(_ index: NodeIndex) -> some View {
        switch viewMode {
        case .tree:
            ExpandedTreeView(
                nodeIndex:     index,
                selection:     $selectedNodeID,
                expandedIDs:   $expandedIDs,
                scrollTrigger: scrollTrigger,
                scrollTarget:  scrollTarget
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(
                    nodeIndex:  index,
                    selectedID: selectedNodeID,
                    fileSize:   document.fileSize,
                    formatName: document.formatName
                )
            }

        case .table:
            TableView(nodeIndex: index, selection: $selectedNodeID)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    StatusBar(
                        nodeIndex: index,
                        selectedID: selectedNodeID,
                        fileSize: document.fileSize,
                        formatName: document.formatName
                    )
                }

        case .raw:
            rawView
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // ── Table view toggle (only when the document is tabular) ──────────
        ToolbarItem(placement: .primaryAction) {
            if let index = document.nodeIndex, index.isTabular() {
                Toggle(isOn: Binding(
                    get:  { viewMode == .table },
                    set:  { viewMode = $0 ? .table : .tree }
                )) {
                    Label("Table View", systemImage: "tablecells")
                }
                .toggleStyle(.button)
                .help(viewMode == .table
                      ? "Switch to tree view"
                      : "Switch to table view")
            }
        }

        // ── Export menu ────────────────────────────────────────────────────
        ToolbarItem(placement: .primaryAction) {
            if let index = document.nodeIndex {
                Menu {
                    Button("Export as JSON…") {
                        exportDocument(index: index, format: .json)
                    }
                    Button("Export as YAML…") {
                        exportDocument(index: index, format: .yaml)
                    }
                    Button("Export as CSV…") {
                        exportDocument(index: index, format: .csv)
                    }
                    .disabled(!index.isTabular())
                } label: {
                    if isExporting {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting)
                .help("Export document as a different format")
            }
        }

        // ── Raw text toggle ────────────────────────────────────────────────
        ToolbarItem(placement: .primaryAction) {
            if document.nodeIndex != nil {
                Toggle(isOn: Binding(
                    get:  { viewMode == .raw },
                    set:  { viewMode = $0 ? .raw : .tree }
                )) {
                    if isSerializingRaw {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Label(
                            viewMode == .raw ? "Tree View" : "Raw JSON",
                            systemImage: viewMode == .raw
                                ? "list.bullet.indent"
                                : "doc.plaintext"
                        )
                    }
                }
                .toggleStyle(.button)
                .help(viewMode == .raw ? "Switch to tree view" : "View raw JSON source")
                .disabled(isSerializingRaw)
            }
        }

        // ── Search navigation (P4-01) ──────────────────────────────────────
        // Shown only when a search is active and produced results.
        ToolbarItem(placement: .primaryAction) {
            if !searchMatches.isEmpty {
                HStack(spacing: 4) {
                    Button(action: previousMatch) {
                        Image(systemName: "chevron.up")
                    }
                    .help("Previous match (⇧↩)")
                    .buttonStyle(.borderless)

                    Text("\(activeMatchIndex + 1) of \(searchMatches.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 56)

                    Button(action: advanceMatch) {
                        Image(systemName: "chevron.down")
                    }
                    .help("Next match (↩)")
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Raw view (P2-09)

    private var rawView: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(rawText)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    /// Serialize the document asynchronously and update `rawText`.
    private func refreshRawText() {
        guard !isSerializingRaw else { return }
        isSerializingRaw = true
        Task {
            do {
                rawText = try await document.serializeDocument(pretty: true)
            } catch {
                rawText = "// Serialization error: \(error.localizedDescription)"
            }
            isSerializingRaw = false
        }
    }

    // MARK: - Export (P3-07)

    /// Present a save panel and write the converted document to the chosen URL.
    private func exportDocument(index: NodeIndex, format: FormatConverter.TargetFormat) {
        guard !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [utType(for: format)]
        panel.canCreateDirectories = true
        let base = (document.fileName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
        panel.begin { [weak document] response in
            guard response == .OK, let url = panel.url else { return }
            isExporting = true
            let mappedFile = document?.mappedFile
            Task.detached(priority: .userInitiated) {
                do {
                    let data = try FormatConverter().convert(
                        index: index,
                        mappedFile: mappedFile,
                        to: format
                    )
                    try data.write(to: url, options: .atomic)
                } catch {
                    await MainActor.run {
                        exportError = error.localizedDescription
                    }
                }
                await MainActor.run { isExporting = false }
            }
        }
    }

    // MARK: - Search (P4-01)

    /// Launch a background search task, cancelling any prior one.
    ///
    /// Results are returned in DFS document order so ↑↓ navigation feels
    /// natural.  The task is cheap to cancel because `SearchEngine.search`
    /// is a synchronous, non-blocking scan.
    private func scheduleSearch(query: String, in index: NodeIndex) {
        searchTask?.cancel()
        activeMatchIndex = 0

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchMatches = []
            return
        }

        searchTask = Task {
            // Run the O(n) scan on a background thread to keep the UI fluid
            // on very large documents (100 k+ nodes).
            let results = await Task.detached(priority: .userInitiated) {
                SearchEngine.search(query: query, in: index)
            }.value

            guard !Task.isCancelled else { return }

            searchMatches    = results
            activeMatchIndex = 0

            if let first = results.first {
                expandPath(to: first.rowNodeID, in: index)
                selectedNodeID = first.rowNodeID
                scrollTrigger += 1
                scrollTarget   = first.rowNodeID
            }
        }
    }

    /// Navigate to the next match (wraps around).
    private func advanceMatch() {
        guard !searchMatches.isEmpty else { return }
        activeMatchIndex = (activeMatchIndex + 1) % searchMatches.count
        navigateToCurrentMatch()
    }

    /// Navigate to the previous match (wraps around).
    private func previousMatch() {
        guard !searchMatches.isEmpty else { return }
        activeMatchIndex = (activeMatchIndex - 1 + searchMatches.count) % searchMatches.count
        navigateToCurrentMatch()
    }

    /// Shared logic for both `advanceMatch` and `previousMatch`:
    /// expand collapsed ancestors, select the row, and request a scroll.
    private func navigateToCurrentMatch() {
        let match = searchMatches[activeMatchIndex]
        if let index = document.nodeIndex {
            expandPath(to: match.rowNodeID, in: index)
        }
        selectedNodeID = match.rowNodeID
        scrollTrigger += 1
        scrollTarget   = match.rowNodeID
    }

    // MARK: - Expansion helpers (P4-02)

    /// Open every collapsed ancestor of `id` in the displayed tree so the
    /// target row becomes visible.
    ///
    /// `index.path(to:)` returns `[rootID, …, id]`.  We skip the root (shown
    /// as `rootRows`, not as an expandable row itself) and the target (we want
    /// to scroll to it, not open it).  For each intermediate node we construct
    /// a `TreeNode` and, if it has displayable children, add it to `expandedIDs`.
    private func expandPath(to id: NodeID, in index: NodeIndex) {
        let pathIDs = index.path(to: id)
        guard pathIDs.count > 2 else { return }   // nothing to expand between root and target

        for nodeID in pathIDs.dropFirst().dropLast() {
            guard let docNode = index.node(for: nodeID) else { continue }
            let treeNode = TreeNode(documentNode: docNode, nodeIndex: index)
            // Only insert IDs that ExpandedTreeView recognises as expandable.
            // Non-row nodes (e.g. the hidden container child of a keyValue row)
            // will simply never appear in flatRows, so adding their IDs is safe.
            if treeNode.children != nil {
                expandedIDs.insert(nodeID)
            }
        }
    }

    /// Map a `TargetFormat` to its `UTType` for the save panel filter.
    private func utType(for format: FormatConverter.TargetFormat) -> UTType {
        switch format {
        case .json: return .json
        case .yaml: return UTType(filenameExtension: "yaml") ?? .data
        case .csv:  return .commaSeparatedText
        }
    }

    // MARK: - State views

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Parsing \(document.fileName)…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: Error) -> some View {
        ContentUnavailableView(
            "Failed to Open File",
            systemImage: "exclamationmark.triangle",
            description: Text(error.localizedDescription)
        )
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            Image(systemName: "curlybraces")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)
            Text("MachStruct")
                .font(.title2.weight(.semibold))
            Text("No content to display.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Placeholder") {
    ContentView(document: StructDocument())
}
