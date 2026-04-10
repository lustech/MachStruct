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

    // MARK: - Persisted settings (P6-01)

    @AppStorage(AppSettings.Keys.rawFontSize)
    private var rawFontSize = AppSettings.Defaults.rawFontSize

    @AppStorage(AppSettings.Keys.treeFontSize)
    private var treeFontSize = AppSettings.Defaults.treeFontSize

    @AppStorage(AppSettings.Keys.defaultRawPretty)
    private var defaultRawPretty = AppSettings.Defaults.defaultRawPretty

    // MARK: - View state

    /// Lifted here so StatusBar can observe selection changes.
    @State private var selectedNodeID: NodeID?

    /// Active content mode (tree / table / raw).
    @State private var viewMode: ViewMode = .tree

    /// Buffered raw text.  Populated asynchronously when switching to `.raw`
    /// so the main thread is never blocked.
    @State private var rawText: String = ""

    /// Syntax-highlighted version of `rawText` (computed after serialisation).
    /// `nil` while being computed or when text exceeds the highlight limit.
    @State private var highlightedRawText: AttributedString? = nil

    /// True while raw text is being serialized in the background.
    @State private var isSerializingRaw: Bool = false

    /// When true the raw view shows pretty-printed output; false = minified. (P4-04)
    /// Initialised from the user's `defaultRawPretty` preference when first
    /// entering raw view; the segmented picker can then override it per-session.
    @State private var rawPretty: Bool = true

    /// True when the CSV column statistics sheet is visible.
    @State private var showCSVStats: Bool = false

    // MARK: - Navigation history

    /// Ordered list of node IDs visited during this session.
    @State private var navHistory: [NodeID] = []

    /// Index into `navHistory` of the currently displayed node.
    /// -1 = no history yet.
    @State private var navHistoryIndex: Int = -1

    /// Set to `true` while `goBack()` / `goForward()` update `selectedNodeID`
    /// to suppress re-pushing to history.
    @State private var isNavigatingHistory: Bool = false

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

    // MARK: - Bookmark state (P4-03)

    /// Ordered list of bookmarked node IDs (insertion order preserved for display).
    ///
    /// In-session only: NodeIDs are counter-based and change on each document
    /// open, so bookmarks do not persist across sessions.  Path-based persistence
    /// is planned as a future improvement.
    @State private var bookmarks: [NodeID] = []

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
                    .environment(\.bookmarkedNodeIDs, Set(bookmarks))
                    .environment(\.toggleBookmark, makeToggleBookmark($bookmarks))
                    .onChange(of: viewMode) { _, mode in
                        if mode == .raw {
                            // Honour the user's preferred default mode each
                            // time they open raw view (can still be overridden
                            // per-session by the pretty/minify picker).
                            rawPretty = defaultRawPretty
                            refreshRawText()
                        }
                    }
                    .onChange(of: selectedNodeID) { _, newID in
                        guard !isNavigatingHistory, let id = newID else { return }
                        pushHistory(id)
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
        .sheet(isPresented: $showCSVStats) {
            if let index = document.nodeIndex {
                CSVStatsPanel(nodeIndex: index)
            }
        }
        // Cmd+D: toggle bookmark on the currently selected node (P4-03).
        // A hidden Button is the idiomatic SwiftUI way to bind a keyboard
        // shortcut to an action without a visible control.
        .background {
            // Cmd+D — toggle bookmark on selected node (P4-03)
            Button("Toggle Bookmark") {
                if let id = selectedNodeID { toggleBookmark(id) }
            }
            .keyboardShortcut("d", modifiers: .command)
            .hidden()

            // Cmd+[ / Cmd+] — back / forward history
            if let index = document.nodeIndex {
                Button("Go Back")    { goBack(in: index)    }
                    .keyboardShortcut("[", modifiers: .command)
                    .hidden()
                Button("Go Forward") { goForward(in: index) }
                    .keyboardShortcut("]", modifiers: .command)
                    .hidden()
            }
        }
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

        // ── CSV column stats (P4 quick win) ──────────────────────────────
        ToolbarItem(placement: .primaryAction) {
            if document.nodeIndex != nil, document.formatName == "CSV" {
                Button {
                    showCSVStats = true
                } label: {
                    Label("Column Stats", systemImage: "chart.bar.xaxis")
                }
                .help("Show CSV column statistics")
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
                            viewMode == .raw ? "Tree View" : "Raw Text",
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

        // ── Pretty / Minify toggle (P4-04) — only visible in raw text view ──
        ToolbarItem(placement: .primaryAction) {
            if viewMode == .raw {
                Picker("Format", selection: $rawPretty) {
                    Image(systemName: "text.alignleft").tag(true)
                        .help("Pretty-print")
                    Image(systemName: "arrow.left.and.right.text.vertical").tag(false)
                        .help("Minify")
                }
                .pickerStyle(.segmented)
                .frame(width: 64)
                .help(rawPretty ? "Switch to minified output" : "Switch to pretty-printed output")
                .disabled(isSerializingRaw)
                .onChange(of: rawPretty) { _, _ in refreshRawText() }
            }
        }

        // ── Bookmarks menu (P4-03) ────────────────────────────────────────
        ToolbarItem(placement: .primaryAction) {
            if let index = document.nodeIndex {
                Menu {
                    if bookmarks.isEmpty {
                        Text("No bookmarks")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(bookmarks, id: \.self) { nodeID in
                            Button(index.pathString(to: nodeID)) {
                                navigateToBookmark(nodeID, in: index)
                            }
                        }
                        Divider()
                        Button("Clear All Bookmarks", role: .destructive) {
                            bookmarks = []
                        }
                    }
                } label: {
                    Label("Bookmarks",
                          systemImage: bookmarks.isEmpty ? "bookmark" : "bookmark.fill")
                }
                .help("Bookmarks (⌘D to toggle)")
            }
        }

        // ── Navigation history (back / forward) ───────────────────────────
        ToolbarItem(placement: .navigation) {
            if let index = document.nodeIndex {
                HStack(spacing: 0) {
                    Button(action: { goBack(in: index) }) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(navHistoryIndex <= 0)
                    .help("Go back (⌘[)")

                    Button(action: { goForward(in: index) }) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(navHistoryIndex >= navHistory.count - 1)
                    .help("Go forward (⌘])")
                }
                .buttonStyle(.borderless)
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

    // MARK: - Raw view (P2-09, syntax highlighting added as quick win)

    private var rawView: some View {
        ScrollView([.horizontal, .vertical]) {
            Group {
                if let highlighted = highlightedRawText {
                    // Highlighted AttributedString — font is baked in by SyntaxHighlighter.
                    Text(highlighted)
                        .textSelection(.enabled)
                } else {
                    // Plain fallback while highlighting runs, or for oversized files.
                    Text(rawText)
                        .font(.system(size: rawFontSize, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    /// Serialize the document asynchronously, then apply syntax highlighting.
    ///
    /// Respects `rawPretty`: pretty-prints when `true`, minifies when `false` (P4-04).
    /// Highlighting runs on a second background task so serialisation latency is
    /// unchanged for large files.
    private func refreshRawText() {
        guard !isSerializingRaw else { return }
        isSerializingRaw   = true
        highlightedRawText = nil
        let pretty     = rawPretty
        let formatName = document.formatName
        let fontSize   = rawFontSize
        Task {
            do {
                let text = try await document.serializeDocument(pretty: pretty)
                rawText = text

                // Highlight on a utility-priority background thread.
                if let fmt = SyntaxHighlighter.Format(formatName: formatName) {
                    let attributed = await Task.detached(priority: .utility) {
                        SyntaxHighlighter.highlight(text, format: fmt, fontSize: fontSize)
                    }.value
                    highlightedRawText = attributed
                }
            } catch {
                rawText            = "// Serialization error: \(error.localizedDescription)"
                highlightedRawText = nil
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
            // Debounce: let the user finish typing before paying for a full scan.
            // 150 ms is imperceptible to humans but eliminates most wasted work
            // caused by fast keystrokes.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

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

        // Collect all IDs to expand first, then apply as a single batch so
        // SwiftUI only re-renders once (not N times for N ancestors).
        var toExpand = Set<NodeID>()
        for nodeID in pathIDs.dropFirst().dropLast() {
            guard let docNode = index.node(for: nodeID) else { continue }
            let treeNode = TreeNode(documentNode: docNode, nodeIndex: index)
            if treeNode.children != nil {
                toExpand.insert(nodeID)
            }
        }
        if !toExpand.isEmpty {
            expandedIDs.formUnion(toExpand)
        }
    }

    // MARK: - Bookmarks (P4-03)

    /// Add or remove `id` from the bookmark list, preserving insertion order.
    private func toggleBookmark(_ id: NodeID) {
        if let idx = bookmarks.firstIndex(of: id) {
            bookmarks.remove(at: idx)
        } else {
            bookmarks.append(id)
        }
    }

    /// Returns a stable escaping closure that toggles a node in/out of
    /// the bookmark list.  Captures the `Binding` (not the value) so it
    /// stays correct across SwiftUI body re-evaluations.
    private func makeToggleBookmark(_ binding: Binding<[NodeID]>) -> (NodeID) -> Void {
        { id in
            if let idx = binding.wrappedValue.firstIndex(of: id) {
                binding.wrappedValue.remove(at: idx)
            } else {
                binding.wrappedValue.append(id)
            }
        }
    }

    /// Expand collapsed ancestors of `id`, select it, and scroll to it —
    /// the same navigation machinery used by search result navigation.
    private func navigateToBookmark(_ id: NodeID, in index: NodeIndex) {
        expandPath(to: id, in: index)
        selectedNodeID = id
        scrollTrigger += 1
        scrollTarget   = id
    }

    /// Map a `TargetFormat` to its `UTType` for the save panel filter.
    private func utType(for format: FormatConverter.TargetFormat) -> UTType {
        switch format {
        case .json: return .json
        case .yaml: return UTType(filenameExtension: "yaml") ?? .data
        case .csv:  return .commaSeparatedText
        }
    }

    // MARK: - Navigation history

    /// Push `id` onto the history stack, truncating any forward entries.
    /// Maximum number of entries kept in the back/forward navigation stack.
    private static let maxHistorySize = 100

    private func pushHistory(_ id: NodeID) {
        // Avoid duplicate consecutive entries (e.g. repeated selection of the
        // same row shouldn't pollute the stack).
        if navHistory.last == id { return }

        // Truncate forward history so going forward after a manual nav is a no-op.
        if navHistoryIndex < navHistory.count - 1 {
            navHistory = Array(navHistory.prefix(navHistoryIndex + 1))
        }
        navHistory.append(id)

        // Drop oldest entries when the history exceeds the cap.
        if navHistory.count > Self.maxHistorySize {
            let overflow = navHistory.count - Self.maxHistorySize
            navHistory.removeFirst(overflow)
        }
        navHistoryIndex = navHistory.count - 1
    }

    private func goBack(in index: NodeIndex) {
        guard navHistoryIndex > 0 else { return }
        navHistoryIndex -= 1
        navigate(to: navHistory[navHistoryIndex], in: index)
    }

    private func goForward(in index: NodeIndex) {
        guard navHistoryIndex < navHistory.count - 1 else { return }
        navHistoryIndex += 1
        navigate(to: navHistory[navHistoryIndex], in: index)
    }

    /// Shared navigation for history back/forward — expands ancestors, selects,
    /// and scrolls without triggering a new history push.
    private func navigate(to id: NodeID, in index: NodeIndex) {
        isNavigatingHistory = true
        expandPath(to: id, in: index)
        selectedNodeID = id
        scrollTrigger += 1
        scrollTarget   = id
        isNavigatingHistory = false
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
