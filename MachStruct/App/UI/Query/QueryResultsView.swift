import SwiftUI
import AppKit
import MachStructCore

// MARK: - QueryResultsView (v2.0 Data Workbench)

/// Displays the output of a jq query in a resizable bottom pane.
///
/// Renders results either as an expandable tree (a transient `NodeIndex` built
/// from the output values) or as raw JSON, with Copy and Export actions.
/// Non-destructive: this view never mutates the source document.
struct QueryResultsView: View {

    /// The query's output values, in document order.
    let results: [JQValue]

    /// Closes the results pane.
    let onClose: () -> Void

    enum Mode: String, CaseIterable { case tree = "Tree", json = "JSON" }

    @State private var mode: Mode = .tree
    @State private var resultIndex: NodeIndex?
    @State private var selection: NodeID?
    @State private var expandedIDs: Set<NodeID> = []

    /// The combined value rendered: a single result is shown directly, multiple
    /// results are wrapped in an array (matching how jq prints a result stream).
    private var combined: JQValue {
        results.count == 1 ? results[0] : .array(results)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minHeight: 120, idealHeight: 220)
        .background(.background)
        .task(id: results) { rebuild() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            Text(results.count == 1 ? "1 result" : "\(results.count) results")
                .font(.callout.weight(.medium))

            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Button { copyJSON() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy results as JSON")
            Menu {
                Button("JSON…") { export(.json) }
                Button("YAML…") { export(.yaml) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()

            Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Close results")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .tree:
            if let index = resultIndex {
                ExpandedTreeView(
                    nodeIndex: index,
                    selection: $selection,
                    expandedIDs: $expandedIDs,
                    scrollTrigger: 0,
                    scrollTarget: nil
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .json:
            ScrollView([.horizontal, .vertical]) {
                Text(combined.jsonString(pretty: true))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
    }

    // MARK: Actions

    private func rebuild() {
        let built = combined.toDocumentNodes(parentID: nil, depth: 0, key: nil)
        var index = NodeIndex(rootID: built.root, allNodes: built.nodes)
        // Reset COW generation observers and expand the root so top-level
        // results are visible immediately.
        _ = index.count
        resultIndex = index
        expandedIDs = [built.root]
        selection = nil
    }

    private func copyJSON() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(combined.jsonString(pretty: true), forType: .string)
    }

    private func export(_ format: FormatConverter.TargetFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "results.\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // JSON is emitted directly (preserves member order); other formats go
        // through the shared converter on the freshly-built results index.
        if format == .json {
            try? combined.jsonString(pretty: true).write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard let index = resultIndex,
              let data = try? FormatConverter().convert(index: index, to: format) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
