import SwiftUI
import MachStructCore

// MARK: - ContentView

/// Root content view for a single document window.
///
/// Delegates to `TreeView` once the document has been parsed.
/// Shows a progress indicator while parsing and an error view on failure.
struct ContentView: View {

    @ObservedObject var document: StructDocument

    /// Lifted here so StatusBar can observe selection changes.
    @State private var selectedNodeID: NodeID?

    var body: some View {
        Group {
            if document.isLoading {
                loadingView
            } else if let error = document.loadError {
                errorView(error)
            } else if let index = document.nodeIndex {
                TreeView(nodeIndex: index, selection: $selectedNodeID)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        StatusBar(
                            nodeIndex: index,
                            selectedID: selectedNodeID,
                            fileSize: document.fileSize,
                            formatName: document.formatName
                        )
                    }
            } else {
                placeholderView
            }
        }
        .frame(minWidth: 400, minHeight: 300)
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
