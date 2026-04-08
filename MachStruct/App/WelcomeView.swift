import SwiftUI
import UniformTypeIdentifiers
import MachStructCore

// MARK: - WelcomeView

/// The launch / welcome window shown on app start instead of the bare system Open panel.
///
/// Provides:
///   - A drag-and-drop zone for JSON / XML / YAML / CSV files
///   - An inline text area for pasting raw structured text (P6-03)
///   - An "Open File…" button (filtered NSOpenPanel via NSDocumentController)
///   - A scrollable recent-files list pulled from NSDocumentController
///   - A clear error state for unsupported file types or parse failures
struct WelcomeView: View {

    @State private var isDraggingOver = false
    @State private var dropError: String?
    @State private var recentURLs: [URL] = []
    @State private var pasteText: String = ""
    @State private var isParsing: Bool = false

    private static let supportedExtensions: Set<String> = ["json", "xml", "yaml", "yml", "csv"]

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
            Divider()
            rightPanel
        }
        .frame(width: 560, height: 460)
        .onAppear { recentURLs = NSDocumentController.shared.recentDocumentURLs }
    }

    // MARK: - Left panel

    private var leftPanel: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("MachStruct")
                .font(.title)
                .fontWeight(.semibold)

            dropZone

            orDivider

            pasteArea

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
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drop zone

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
                    .font(.system(size: 24))
                    .foregroundStyle(isDraggingOver ? Color.accentColor : Color.secondary)

                Text("Drop a file here")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 220, height: 88)
        .animation(.easeInOut(duration: 0.15), value: isDraggingOver)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDraggingOver, perform: handleDrop)
    }

    // MARK: - "or paste text" divider

    private var orDivider: some View {
        HStack(spacing: 8) {
            VStack { Divider() }
            Text("or paste text")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize()
            VStack { Divider() }
        }
        .frame(width: 220)
    }

    // MARK: - Paste area

    private var pasteArea: some View {
        VStack(spacing: 8) {
            // TextEditor has no native placeholder support; use a ZStack overlay.
            ZStack(alignment: .topLeading) {
                TextEditor(text: $pasteText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                    )

                if pasteText.isEmpty {
                    Text("Paste JSON, XML, YAML, or CSV…")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        // Match TextEditor's internal content inset (~5 pt each side).
                        .padding(.horizontal, 5)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 220, height: 90)

            Button(action: parsePastedText) {
                if isParsing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Parsing…")
                    }
                    .frame(minWidth: 90)
                } else {
                    Text("Parse")
                        .frame(minWidth: 90)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isParsing)
        }
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

    /// Parse the pasted text as a structured document and open it in a new window.
    ///
    /// Steps:
    ///   1. Auto-detect format from the first 512 bytes via FormatDetector.
    ///   2. Write to a named temp file so StructDocument.read(from:ofType:) can use
    ///      its existing mmap → parse path with zero changes to the document layer.
    ///   3. Open via NSDocumentController — identical to the file-drop path.
    ///
    /// The document opens titled "Pasted Content" with an immediate dirty state,
    /// so the user is naturally prompted to File › Save As if they want to keep it.
    private func parsePastedText() {
        let trimmed = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isParsing = true

        // 1. Detect format.
        let data = Data(trimmed.utf8)
        let detected = FormatDetector.detect(headerBytes: data, fileExtension: nil)

        let ext: String
        switch detected {
        case .json:    ext = "json"
        case .xml:     ext = "xml"
        case .yaml:    ext = "yaml"
        case .csv:     ext = "csv"
        case .unknown: ext = "json"  // fall through — parser will produce a usable error
        }

        // 2. Write to temp file (overwrites any prior paste; the name is intentionally generic).
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Pasted Content.\(ext)")
        do {
            try data.write(to: tempURL, options: .atomic)
        } catch {
            showDropError("Could not write temp file: \(error.localizedDescription)")
            isParsing = false
            return
        }

        // 3. Open via document controller.
        NSDocumentController.shared.openDocument(
            withContentsOf: tempURL, display: true
        ) { _, _, error in
            DispatchQueue.main.async {
                isParsing = false
                if let error {
                    showDropError(error.localizedDescription)
                } else {
                    pasteText = ""
                    recentURLs = NSDocumentController.shared.recentDocumentURLs
                }
            }
        }
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
