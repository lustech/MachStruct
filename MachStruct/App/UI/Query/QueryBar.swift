import SwiftUI
import MachStructCore

// MARK: - QueryBar (v2.0 Data Workbench)

/// The jq query input bar shown above the results pane.
///
/// Owns only its text field focus; query text, error, running state, and the
/// apply controls are bound from `ContentView`, which runs the query through
/// `QueryEngine` and applies path-only results through `EditTransaction`.
struct QueryBar: View {

    @Binding var query: String

    /// Parse/runtime error message for the current query, or `nil`.
    let errorMessage: String?

    /// True while a query is running (shows a spinner, disables Run).
    let isRunning: Bool

    /// True when the last successful query was path-only and can be applied
    /// back to the document (enables the Apply menu).
    let canApply: Bool

    let onRun: () -> Void
    let onApplyDelete: () -> Void
    let onApplySetValue: (String) -> Void
    let onClose: () -> Void

    @FocusState private var focused: Bool
    @State private var setValueText: String = ""
    @State private var showSetValue = false
    @State private var saveName = ""
    @State private var showSave = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)

                TextField("jq filter — e.g. .users[] | select(.age > 30) | .name",
                          text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($focused)
                    .onSubmit(onRun)

                historyMenu

                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Run", action: onRun)
                        .keyboardShortcut(.return, modifiers: [])
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                applyMenu

                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Close query bar")
            }

            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onAppear { focused = true }
    }

    // MARK: History / saved queries

    private var historyMenu: some View {
        Menu {
            let saved = QueryStore.savedQueries()
            if !saved.isEmpty {
                Section("Saved") {
                    ForEach(saved) { item in
                        Button(item.name) { query = item.query; onRun() }
                    }
                }
            }
            let recent = QueryStore.recentQueries()
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent, id: \.self) { q in
                        Button(q) { query = q; onRun() }
                    }
                }
            }
            Divider()
            Button("Save Current Query…") { showSave = true }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Saved & recent queries")
        .popover(isPresented: $showSave) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Save query as:").font(.callout)
                TextField("Name", text: $saveName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                HStack {
                    Spacer()
                    Button("Cancel") { showSave = false; saveName = "" }
                    Button("Save") {
                        QueryStore.save(name: saveName, query: query)
                        showSave = false; saveName = ""
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
        }
    }

    // MARK: Apply

    private var applyMenu: some View {
        Menu {
            Button("Delete Matched Nodes", role: .destructive, action: onApplyDelete)
            Button("Set Value…") { showSetValue = true }
        } label: {
            Label("Apply", systemImage: "checkmark.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!canApply)
        .help(canApply
              ? "Apply this path query to the document"
              : "Only path queries (no construction) can be applied")
        .popover(isPresented: $showSetValue) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Set matched values to:").font(.callout)
                TextField("New value", text: $setValueText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                HStack {
                    Spacer()
                    Button("Cancel") { showSetValue = false }
                    Button("Apply") {
                        onApplySetValue(setValueText)
                        showSetValue = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
    }
}
