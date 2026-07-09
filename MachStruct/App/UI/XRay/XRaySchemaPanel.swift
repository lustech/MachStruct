import SwiftUI
import MachStructCore

// MARK: - SchemaRow (display model)

/// Flattened display row for one inferred-schema node.
struct SchemaRow: Identifiable, Sendable {
    let id = UUID()
    let name: String            // field key, "[ ] element", or the root label
    let signature: String       // e.g. "string?", "object[]", "int | string"
    let detail: String?         // e.g. "in 4,821 of 10,000"
    let isOptional: Bool
    let conflictMessage: String?
    let children: [SchemaRow]?  // nil = leaf (renders without disclosure)
}

// MARK: - XRaySchemaPanel

/// X-Ray Mode (FEATURE-IDEAS #1): sheet showing the inferred implicit schema
/// of the document — field types merged across array elements, optionality
/// from presence counts, and type inconsistencies (e.g. `age` is a string in
/// 3 of 10,000 records).
struct XRaySchemaPanel: View {

    /// Retained for lazy/large files; `nil` for small eagerly-built files.
    let structuralIndex: StructuralIndex?
    let nodeIndex: NodeIndex?
    let mappedFile: MappedFile?

    @State private var rows: [SchemaRow] = []
    @State private var inconsistencies: [SchemaInconsistency] = []
    @State private var nodesScanned: Int = 0
    @State private var schemaText: String = ""
    @State private var isLoading: Bool = true

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {

            // ── Header bar ────────────────────────────────────────────────
            HStack {
                Label("X-Ray — Inferred Schema", systemImage: "cube.transparent")
                    .font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(schemaText, forType: .string)
                } label: {
                    Label("Copy Schema", systemImage: "doc.on.doc")
                }
                .disabled(isLoading || schemaText.isEmpty)
                .help("Copy the schema as indented text")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(.regularMaterial)

            Divider()

            // ── Content ───────────────────────────────────────────────────
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Inferring schema…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "No Schema",
                    systemImage: "cube.transparent",
                    description: Text("The document has no analysable structure.")
                )
            } else {
                List {
                    if !inconsistencies.isEmpty {
                        Section {
                            ForEach(Array(inconsistencies.enumerated()),
                                    id: \.offset) { _, inc in
                                Label {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(inc.path)
                                            .font(.system(.body, design: .monospaced))
                                        Text(inc.message)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                        } header: {
                            Text("\(inconsistencies.count) type inconsistenc\(inconsistencies.count == 1 ? "y" : "ies")")
                        }
                    }

                    Section("Schema") {
                        OutlineGroup(rows, children: \.children) { row in
                            SchemaRowView(row: row)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            // ── Footer ────────────────────────────────────────────────────
            HStack {
                Text(isLoading ? " " : "\(nodesScanned) nodes analysed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !isLoading && structuralIndex != nil {
                    // Large files infer from the parse-time index, which
                    // EditTransaction does not update.
                    Text("Reflects the file as loaded — unsaved edits not included")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { await inferSchema() }
    }

    // MARK: - Inference

    /// Everything derived from the schema (rows, inconsistency list, copy
    /// text) is built inside the detached task too — for map-like documents
    /// the schema tree scales with the document, and building it on the main
    /// actor would beachball the UI behind the spinner.
    @MainActor
    private func inferSchema() async {
        isLoading = true
        let si = structuralIndex
        let idx = nodeIndex
        let file = mappedFile

        struct Display: Sendable {
            let rows: [SchemaRow]
            let inconsistencies: [SchemaInconsistency]
            let nodesScanned: Int
            let text: String
        }
        // Detached tasks don't inherit `.task`-modifier cancellation, so
        // forward it explicitly — dismissing the sheet stops the scan.
        let handle = Task.detached(priority: .userInitiated) { () -> Display? in
            let schema: InferredSchema
            if let si {
                schema = SchemaInferenceEngine.infer(from: si, file: file)
            } else if let idx {
                schema = SchemaInferenceEngine.infer(from: idx, file: file)
            } else {
                return nil
            }
            guard !Task.isCancelled else { return nil }
            return Display(
                rows: [Self.makeRow(name: "root", node: schema.root,
                                    presenceDetail: nil, isOptional: false)],
                inconsistencies: schema.inconsistencies,
                nodesScanned: schema.nodesScanned,
                text: schema.renderedText)
        }
        let display: Display? = await withTaskCancellationHandler {
            await handle.value
        } onCancel: {
            handle.cancel()
        }

        if let display {
            rows            = display.rows
            inconsistencies = display.inconsistencies
            nodesScanned    = display.nodesScanned
            schemaText      = display.text
        }
        isLoading = false
    }

    // MARK: - Display-model construction

    private nonisolated static func makeRow(name: String,
                                node: SchemaNode,
                                presenceDetail: String?,
                                isOptional: Bool) -> SchemaRow {
        var children: [SchemaRow] = []

        for field in node.fields {
            let objectCount = node.kindCounts[.object] ?? 0
            let detail = field.isOptional && objectCount > 1
                ? "in \(field.presence.formatted()) of \(objectCount.formatted())"
                : nil
            children.append(makeRow(name: field.key,
                                    node: field.schema,
                                    presenceDetail: detail,
                                    isOptional: field.isOptional))
        }
        if let element = node.element {
            children.append(makeRow(name: "[ ] element",
                                    node: element,
                                    presenceDetail: "× \(element.occurrences.formatted())",
                                    isOptional: false))
        }
        if node.isDepthTruncated {
            children.append(SchemaRow(name: "…",
                                      signature: "deeper levels not analysed",
                                      detail: nil, isOptional: false,
                                      conflictMessage: nil, children: nil))
        }

        let sig = node.typeSignature + (isOptional && !node.typeSignature.hasSuffix("?") ? "?" : "")
        return SchemaRow(name: name,
                         signature: sig,
                         detail: presenceDetail,
                         isOptional: isOptional,
                         conflictMessage: node.conflictDescription,
                         children: children.isEmpty ? nil : children)
    }

}

// MARK: - SchemaRowView

private struct SchemaRowView: View {
    let row: SchemaRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.name)
                .font(.system(.body, design: .monospaced))

            Text(row.signature)
                .font(.caption.bold())
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(badgeColor.opacity(0.15), in: Capsule())
                .foregroundStyle(badgeColor)

            if let detail = row.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let conflict = row.conflictMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(conflict)
            }

            Spacer()
        }
    }

    /// Follows the TypeBadge palette (UI-DESIGN.md §3.1) so the type-color
    /// language matches the main tree view.
    private var badgeColor: Color {
        if row.conflictMessage != nil { return .orange }
        switch row.signature.hasSuffix("?") ? String(row.signature.dropLast())
                                            : row.signature {
        case "string":            return .green
        case "int":               return .blue
        case "number":            return Color(red: 0.6, green: 0.2, blue: 0.8)    // purple
        case "bool":              return .orange
        case "null":              return Color(white: 0.55)
        case "object":            return Color(red: 0.15, green: 0.60, blue: 0.55) // teal
        case let s where s.hasSuffix("[]") || s == "array":
                                  return Color(red: 0.36, green: 0.38, blue: 0.80) // indigo
        default:                  return .orange   // unions
        }
    }
}
