import SwiftUI
import AppKit
import MachStructCore

// MARK: - PaletteCommand

/// A single runnable action surfaced in the command palette.
///
/// Commands are gathered fresh each time the palette is opened so they reflect
/// the current document context (e.g. "Switch to Raw View" only appears when a
/// document is loaded; "Export as CSV…" only when tabular).
struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let symbol: String?
    let perform: () -> Void

    init(_ title: String,
         subtitle: String? = nil,
         symbol: String? = nil,
         perform: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.perform = perform
    }
}

// MARK: - CommandPaletteView

/// VS Code-style fuzzy palette. Shown as a sheet from the active document
/// window. Substring scoring (case-insensitive) ranks matches; a prefix match
/// boosts the score so exact-typed actions surface first.
struct CommandPaletteView: View {

    let commands: [PaletteCommand]
    let onDismiss: () -> Void

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isFocused: Bool

    private var filtered: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        return commands
            .compactMap { cmd -> (PaletteCommand, Int)? in
                let t = cmd.title.lowercased()
                let s = (cmd.subtitle ?? "").lowercased()
                if t.hasPrefix(q)            { return (cmd, 0) }
                if t.contains(q)             { return (cmd, 1) }
                if s.contains(q)             { return (cmd, 2) }
                return nil
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isFocused)
                    .onSubmit { runSelected() }
                    .onKeyPress(.escape)    { onDismiss(); return .handled }
                    .onKeyPress(.upArrow)   { moveSelection(-1); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(+1); return .handled }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if filtered.isEmpty {
                Text("No matching commands")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { (idx, cmd) in
                                row(cmd: cmd, isSelected: idx == selectedIndex)
                                    .id(cmd.id)
                                    .onTapGesture { run(cmd) }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selectedIndex) { _, _ in
                        guard selectedIndex < filtered.count else { return }
                        withAnimation(.linear(duration: 0.08)) {
                            proxy.scrollTo(filtered[selectedIndex].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 540)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onAppear { isFocused = true }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(cmd: PaletteCommand, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: cmd.symbol ?? "circle.dotted")
                .frame(width: 18)
                .foregroundStyle(isSelected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(cmd.title)
                    .foregroundStyle(isSelected ? .white : .primary)
                if let sub = cmd.subtitle {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let n = filtered.count
        selectedIndex = (selectedIndex + delta + n) % n
    }

    private func runSelected() {
        guard selectedIndex < filtered.count else { return }
        run(filtered[selectedIndex])
    }

    private func run(_ cmd: PaletteCommand) {
        onDismiss()
        // Defer so the sheet has dismissed before the action runs (avoids
        // re-entrancy when the action itself presents UI).
        DispatchQueue.main.async { cmd.perform() }
    }
}

// MARK: - Preview

#Preview {
    CommandPaletteView(
        commands: [
            PaletteCommand("Expand All",        symbol: "chevron.down.circle",  perform: {}),
            PaletteCommand("Collapse All",      symbol: "chevron.up.circle",    perform: {}),
            PaletteCommand("Toggle Bookmark",   subtitle: "⌘D",                 symbol: "bookmark", perform: {}),
            PaletteCommand("Switch to Raw View", subtitle: "JSON source",       symbol: "doc.plaintext", perform: {}),
            PaletteCommand("Export as JSON…",   symbol: "square.and.arrow.up",  perform: {}),
            PaletteCommand("Settings…",         subtitle: "⌘,",                 symbol: "gearshape", perform: {}),
        ],
        onDismiss: {}
    )
}
