import AppKit
import SwiftUI
import Combine

// MARK: - DetectedClipboard

struct DetectedClipboard: Equatable {
    let text:   String
    let format: String   // "JSON" | "XML" | "YAML" | "CSV"
}

// MARK: - ClipboardWatcher

/// Polls `NSPasteboard` every 1.5 s and publishes `detected` when the
/// clipboard changes to contain valid structured text.
///
/// Heuristic detection is intentionally lightweight (no full parse) so it
/// never blocks the main thread:
///   - `{` / `[` at start → JSON
///   - `<` at start       → XML
///   - `key: value` lines → YAML
///   - comma-separated rows → CSV
///
/// Text larger than 2 MB or smaller than 3 characters is ignored.
@MainActor
final class ClipboardWatcher: ObservableObject {

    @Published var detected: DetectedClipboard? = nil

    private var timer:           Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Polling

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        guard let text = pb.string(forType: .string),
              text.count >= 3,
              text.utf8.count <= 2_000_000 else {
            detected = nil
            return
        }

        // Detect on a background thread — heuristic is cheap but we still
        // want to keep the main thread free.
        let snapshot = text
        Task.detached(priority: .utility) { [weak self] in
            let format = Self.sniff(snapshot)
            let watcher = self
            await MainActor.run {
                watcher?.detected = format.map { DetectedClipboard(text: snapshot, format: $0) }
            }
        }
    }

    // MARK: - Heuristic sniffer

    /// Returns a format name if `text` looks like structured data, else `nil`.
    private nonisolated static func sniff(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let first = trimmed.unicodeScalars.first!.value

        // JSON — starts with { or [
        if first == 0x7B || first == 0x5B {   // { [
            // Quick structural sanity: must contain at least one : or ,
            if trimmed.contains(":") || trimmed.contains(",") {
                return "JSON"
            }
        }

        // XML — starts with < and contains a closing >
        if first == 0x3C && trimmed.contains(">") {   // <
            return "XML"
        }

        // YAML — has `key: value` lines (but not XML/JSON)
        let lines = trimmed.components(separatedBy: "\n").prefix(10)
        let yamlLike = lines.filter { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            return !l.hasPrefix("#") && l.contains(": ")
        }.count
        if yamlLike >= 2 {
            return "YAML"
        }

        // CSV — multiple lines, each with same number of commas/tabs
        let csvLines = trimmed.components(separatedBy: "\n").filter { !$0.isEmpty }
        if csvLines.count >= 2 {
            let delim: Character = trimmed.contains("\t") ? "\t" : ","
            let counts = csvLines.prefix(5).map { $0.filter { $0 == delim }.count }
            if let first = counts.first, first > 0, counts.allSatisfy({ $0 == first }) {
                return "CSV"
            }
        }

        return nil
    }
}

// MARK: - ClipboardBanner

/// A dismissible banner shown above the welcome window when structured
/// data is detected on the clipboard.
struct ClipboardBanner: View {

    let detected: DetectedClipboard
    let onOpen:   (DetectedClipboard) -> Void
    let onDismiss: () -> Void

    private var icon: String {
        switch detected.format {
        case "JSON": return "curlybraces"
        case "XML":  return "chevron.left.forwardslash.chevron.right"
        case "YAML": return "list.dash"
        case "CSV":  return "tablecells"
        default:     return "doc.plaintext"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(detected.format) detected on clipboard")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(detected.text.count.formatted()) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open") { onOpen(detected) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(0.25))
        )
        .padding(.horizontal, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
