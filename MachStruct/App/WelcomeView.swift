import SwiftUI
import UniformTypeIdentifiers

// MARK: - WelcomeView

/// The launch / welcome window shown on app start instead of the bare system Open panel.
///
/// Provides:
///   - A drag-and-drop zone for JSON / XML / YAML / CSV files
///   - An "Open File…" button (filtered NSOpenPanel via NSDocumentController)
///   - A scrollable recent-files list pulled from NSDocumentController
///   - A clear error state for unsupported file types dropped onto the zone
struct WelcomeView: View {

    @State private var isDraggingOver = false
    @State private var dropError: String?
    @State private var recentURLs: [URL] = []

    private static let supportedExtensions: Set<String> = ["json", "xml", "yaml", "yml", "csv"]

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
            Divider()
            rightPanel
        }
        .frame(width: 560, height: 360)
        .onAppear { recentURLs = NSDocumentController.shared.recentDocumentURLs }
    }

    // MARK: - Left panel

    private var leftPanel: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)

            Text("MachStruct")
                .font(.title)
                .fontWeight(.semibold)

            dropZone

            if let error = dropError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity)
                    .animation(.easeInOut, value: dropError)
            }

            Button(action: openFilePicker) {
                Label("Open File…", systemImage: "folder")
                    .frame(width: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDraggingOver ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 5])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isDraggingOver
                              ? Color.accentColor.opacity(0.08)
                              : Color.secondary.opacity(0.04))
                )

            VStack(spacing: 6) {
                Image(systemName: isDraggingOver ? "arrow.down.doc.fill" : "arrow.down.doc")
                    .font(.system(size: 26))
                    .foregroundStyle(isDraggingOver ? Color.accentColor : Color.secondary)

                Text("Drop a file here")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 220, height: 110)
        .animation(.easeInOut(duration: 0.15), value: isDraggingOver)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDraggingOver, perform: handleDrop)
    }

    // MARK: - Right panel

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Files")
                .font(.headline)
                .padding(.bottom, 10)
                .padding(.top, 24)
                .padding(.horizontal, 16)

            if recentURLs.isEmpty {
                Spacer()
                Text("No recent files")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(recentURLs, id: \.self) { url in
                            RecentFileRow(url: url) {
                                recentURLs = NSDocumentController.shared.recentDocumentURLs
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(minWidth: 240, maxWidth: 240, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    // MARK: - Actions

    private func openFilePicker() {
        NSDocumentController.shared.openDocument(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            recentURLs = NSDocumentController.shared.recentDocumentURLs
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        // loadDataRepresentation (macOS 10.13+) keeps the Data alive until the
        // completion block returns and is not deprecated, unlike loadItem(forTypeIdentifier:).
        _ = provider.loadDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier
        ) { data, _ in
            // Jump to main before touching any Swift COW values or AppKit APIs.
            DispatchQueue.main.async {
                guard let data,
                      let url = URL(dataRepresentation: data,
                                    relativeTo: nil,
                                    isAbsolute: true)
                else {
                    showDropError("Could not read the dropped file.")
                    return
                }
                let ext = url.pathExtension.lowercased()
                if Self.supportedExtensions.contains(ext) {
                    dropError = nil
                    NSDocumentController.shared.openDocument(
                        withContentsOf: url, display: true
                    ) { _, _, _ in
                        DispatchQueue.main.async {
                            recentURLs = NSDocumentController.shared.recentDocumentURLs
                        }
                    }
                } else {
                    showDropError("Unsupported file type: .\(ext.isEmpty ? "(none)" : ext)")
                }
            }
        }
        return true
    }

    private func showDropError(_ message: String) {
        dropError = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if dropError == message { dropError = nil }
        }
    }
}

// MARK: - RecentFileRow

private struct RecentFileRow: View {
    let url: URL
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: fileIcon(for: url))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(url.deletingLastPathComponent().abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.secondary.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private func open() {
        NSDocumentController.shared.openDocument(
            withContentsOf: url, display: true
        ) { _, _, _ in }
        onOpen()
    }

    private func fileIcon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "json":            return "curlybraces"
        case "xml":             return "chevron.left.forwardslash.chevron.right"
        case "yaml", "yml":     return "list.dash"
        case "csv":             return "tablecells"
        default:                return "doc"
        }
    }
}

// MARK: - URL + display helpers

private extension URL {
    /// Returns the path with the home directory replaced by "~".
    var abbreviatingWithTildeInPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
