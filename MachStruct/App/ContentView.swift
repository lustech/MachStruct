import SwiftUI
import MachStructCore

// MARK: - ContentView

/// Root content view for a single document window.
///
/// Delegates to `TreeView` once the document has been parsed.
/// Shows a progress indicator while parsing and an error view on failure.
/// A toolbar toggle (P2-09) switches between the structured tree view and a
/// read-only raw JSON text view.
struct ContentView: View {

    @ObservedObject var document: StructDocument

    /// Lifted here so StatusBar can observe selection changes.
    @State private var selectedNodeID: NodeID?

    /// P2-09: toggle between tree view and raw JSON text view.
    @State private var showRaw: Bool = false

    /// Buffered raw JSON string for the text view.  Populated asynchronously
    /// when the user switches to raw mode so the main thread is never blocked.
    @State private var rawText: String = ""

    /// True while the raw text is being serialized in the background.
    @State private var isSerializingRaw: Bool = false

    /// Injected by SwiftUI for native Cmd+Z / Cmd+Shift+Z support.
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if document.isLoading {
                loadingView
            } else if let error = document.loadError {
                errorView(error)
            } else if let index = document.nodeIndex {
                ZStack {
                    // Tree view (always built so state is preserved across toggles).
                    TreeView(nodeIndex: index, selection: $selectedNodeID)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            StatusBar(
                                nodeIndex: index,
                                selectedID: selectedNodeID,
                                fileSize: document.fileSize,
                                formatName: document.formatName
                            )
                        }
                        .opacity(showRaw ? 0 : 1)
                        .allowsHitTesting(!showRaw)

                    // Raw JSON text view (P2-09).
                    if showRaw {
                        rawView
                    }
                }
                // Inject the edit-commit closure so NodeRow (and any descendant)
                // can commit edits and register them with the window's UndoManager.
                .environment(\.commitEdit) { [weak document] tx in
                    document?.commitEdit(tx, undoManager: undoManager)
                }
                // Inject node serializer for copy-as-JSON (P2-08).
                .environment(\.serializeNode) { [weak document] nodeID, pretty in
                    document?.serializeNode(nodeID, pretty: pretty)
                }
                // Build raw text when switching to raw mode.
                .onChange(of: showRaw) { _, isRaw in
                    if isRaw { refreshRawText() }
                }
                // Also refresh raw text when the index changes while raw is visible.
                .onChange(of: index.count) { _, _ in
                    if showRaw { refreshRawText() }
                }
            } else {
                placeholderView
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .toolbar {
            if document.nodeIndex != nil {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $showRaw) {
                        if isSerializingRaw {
                            ProgressView().scaleEffect(0.6)
                        } else {
                            Label(
                                showRaw ? "Tree View" : "Raw JSON",
                                systemImage: showRaw ? "list.bullet.indent" : "doc.plaintext"
                            )
                        }
                    }
                    .toggleStyle(.button)
                    .help(showRaw ? "Switch to tree view" : "View raw JSON source")
                    .disabled(isSerializingRaw)
                }
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
            Text("Drop a JSON file here to open it.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Placeholder") {
    ContentView(document: StructDocument())
}
