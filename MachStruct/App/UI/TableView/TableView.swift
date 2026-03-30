import SwiftUI
import MachStructCore

// MARK: - TableView

/// Spreadsheet-style table for documents whose root is a uniform array of objects.
///
/// ## Layout
/// ```
/// ┌─────────────────────────────────────┐  ← ScrollView(.horizontal)
/// │  name    │  age  │  city           │  ← header row (scrolls horizontally,
/// ├──────────┼───────┼─────────────────┤     pinned above the vertical scroll)
/// │ "Alice"  │  30   │ "NYC"           │  ← ScrollView(.vertical)
/// │ "Bob"    │  25   │ "LA"            │     LazyVStack — only visible rows render
/// │  …                                 │
/// └─────────────────────────────────────┘
/// ```
///
/// Columns come from `NodeIndex.tabularColumns`.  Cell values are resolved
/// lazily — only rows scrolled into view call `nodeIndex.children(of:)`.
///
/// ## Selection
/// Clicking a row sets `selection` to the row's object `NodeID`, keeping it
/// in sync with the tree view's selection binding.
struct TableView: View {

    let nodeIndex: NodeIndex
    @Binding var selection: NodeID?

    // MARK: - Geometry constants (Phase 3: fixed widths; adaptive sizing is P4)

    private let colWidth   : CGFloat = 160
    private let rowHeight  : CGFloat = 26
    private let headerHeight: CGFloat = 32

    // MARK: - Derived data

    /// Column names from the first row's key order.
    private var columns: [String] { nodeIndex.tabularColumns }

    /// Minimum total content width — ensures the scroll area is never narrower
    /// than the window.
    private var totalWidth: CGFloat {
        max(CGFloat(columns.count) * colWidth, 600)
    }

    /// Light-weight row identifiers; children are looked up lazily per-row.
    private struct TableRow: Identifiable { let id: NodeID }

    private var tableRows: [TableRow] {
        guard let root = nodeIndex.root else { return [] }
        return nodeIndex.children(of: root.id).map { TableRow(id: $0.id) }
    }

    // MARK: - Body

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {

                // ── Header ──────────────────────────────────────────────────
                // Placed outside the vertical ScrollView so it stays pinned at
                // the top while rows scroll underneath.
                headerRowView
                    .frame(width: totalWidth, height: headerHeight)
                    .background(Color(NSColor.windowBackgroundColor))

                Divider()

                // ── Data rows ───────────────────────────────────────────────
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(tableRows) { row in
                            dataRowView(row)
                            Divider().opacity(0.35)
                        }
                    }
                    .frame(width: totalWidth)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(width: totalWidth)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Header row

    private var headerRowView: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { col in
                Text(col)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .frame(width: colWidth, alignment: .leading)

                Divider().opacity(0.4)
            }
        }
    }

    // MARK: - Data row

    @ViewBuilder
    private func dataRowView(_ row: TableRow) -> some View {
        let kvs = nodeIndex.children(of: row.id)
        let isSelected = selection == row.id

        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { col in
                cellView(kvs: kvs, column: col)
                Divider().opacity(0.25)
            }
        }
        .frame(height: rowHeight)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selection = row.id }
    }

    // MARK: - Individual cell

    @ViewBuilder
    private func cellView(kvs: [DocumentNode], column: String) -> some View {
        let sv = scalarValue(in: kvs, forKey: column)
        Text(sv?.displayText ?? "")
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(sv.map { typeColor($0) } ?? Color.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .frame(width: colWidth, alignment: .leading)
    }

    // MARK: - Helpers

    /// Resolve the scalar value for a given column from a row's keyValue children.
    private func scalarValue(in kvs: [DocumentNode], forKey key: String) -> ScalarValue? {
        guard let kv = kvs.first(where: { $0.key == key }),
              let scalar = nodeIndex.children(of: kv.id).first,
              case .scalar(let sv) = scalar.value else { return nil }
        return sv
    }

    /// Per-type text colors matching the palette used in `NodeRow`.
    private func typeColor(_ sv: ScalarValue) -> Color {
        switch sv {
        case .string:          return Color(red: 0.8, green: 0.3, blue: 0.1)
        case .integer, .float: return .blue
        case .boolean:         return .orange
        case .null:            return .secondary
        }
    }
}

// MARK: - Preview

#Preview {
    // Build a small in-memory tabular document.
    let root = DocumentNode(type: .array, value: .container(childCount: 2))
    var idx  = NodeIndex(root: root)

    func addRow(name: String, age: Int, city: String) {
        let row   = DocumentNode(id: .generate(), type: .object, depth: 1,
                                 parentID: root.id, value: .container(childCount: 3))
        let kv1   = DocumentNode(id: .generate(), type: .keyValue, depth: 2,
                                 parentID: row.id, key: "name", value: .unparsed)
        let s1    = DocumentNode(id: .generate(), type: .scalar, depth: 3,
                                 parentID: kv1.id, value: .scalar(.string(name)))
        let kv2   = DocumentNode(id: .generate(), type: .keyValue, depth: 2,
                                 parentID: row.id, key: "age", value: .unparsed)
        let s2    = DocumentNode(id: .generate(), type: .scalar, depth: 3,
                                 parentID: kv2.id, value: .scalar(.integer(Int64(age))))
        let kv3   = DocumentNode(id: .generate(), type: .keyValue, depth: 2,
                                 parentID: row.id, key: "city", value: .unparsed)
        let s3    = DocumentNode(id: .generate(), type: .scalar, depth: 3,
                                 parentID: kv3.id, value: .scalar(.string(city)))
        idx.insertChild(row, in: root.id, at: idx.children(of: root.id).count)
        idx.insertChild(kv1, in: row.id, at: 0)
        idx.insertChild(s1,  in: kv1.id, at: 0)
        idx.insertChild(kv2, in: row.id, at: 1)
        idx.insertChild(s2,  in: kv2.id, at: 0)
        idx.insertChild(kv3, in: row.id, at: 2)
        idx.insertChild(s3,  in: kv3.id, at: 0)
    }

    addRow(name: "Alice", age: 30, city: "New York")
    addRow(name: "Bob",   age: 25, city: "Los Angeles")
    addRow(name: "Carol", age: 35, city: "Chicago")

    return TableView(nodeIndex: idx, selection: .constant(nil))
        .frame(width: 600, height: 200)
}
