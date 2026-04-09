import SwiftUI
import MachStructCore

// MARK: - ColumnStats

/// Per-column statistics computed from a tabular `NodeIndex`.
struct ColumnStats: Identifiable {
    let id:          String   // column name
    var totalRows:   Int      = 0
    var emptyCount:  Int      = 0
    var intCount:    Int      = 0
    var floatCount:  Int      = 0
    var stringCount: Int      = 0
    var uniqueValues: Set<String> = []
    var numMin:      Double   = .greatestFiniteMagnitude
    var numMax:      Double   = -.greatestFiniteMagnitude

    var nonEmpty:    Int    { totalRows - emptyCount }
    var uniqueCount: Int    { uniqueValues.count }

    var detectedType: String {
        guard nonEmpty > 0 else { return "Empty" }
        if intCount   == nonEmpty { return "Integer" }
        if intCount + floatCount == nonEmpty { return "Decimal" }
        if stringCount == nonEmpty { return "String" }
        return "Mixed"
    }

    var hasNumericRange: Bool {
        numMin <= numMax
    }
}

// MARK: - CSVStatsPanel

/// Sheet view showing per-column statistics for a tabular (CSV) document.
struct CSVStatsPanel: View {

    let nodeIndex: NodeIndex

    @State private var stats:     [ColumnStats] = []
    @State private var isLoading: Bool          = true

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {

            // ── Header bar ────────────────────────────────────────────────
            HStack {
                Label("Column Statistics", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                Spacer()
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
                    Text("Analysing columns…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if stats.isEmpty {
                ContentUnavailableView(
                    "No Columns",
                    systemImage: "tablecells",
                    description: Text("This document has no tabular data.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(stats) { col in
                            ColumnStatCard(stats: col)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .task { await computeStats() }
    }

    // MARK: - Computation

    @MainActor
    private func computeStats() async {
        isLoading = true
        stats = await Task.detached(priority: .userInitiated) {
            Self.compute(nodeIndex: nodeIndex)
        }.value
        isLoading = false
    }

    private static func compute(nodeIndex: NodeIndex) -> [ColumnStats] {
        let columns = nodeIndex.tabularColumns
        guard !columns.isEmpty, let root = nodeIndex.root else { return [] }

        var result = columns.map { ColumnStats(id: $0) }

        for rowNode in nodeIndex.children(of: root.id) {
            let kvs = nodeIndex.children(of: rowNode.id)

            for (i, col) in columns.enumerated() {
                result[i].totalRows += 1

                guard let kv = kvs.first(where: { $0.key == col }),
                      let child = nodeIndex.children(of: kv.id).first else {
                    result[i].emptyCount += 1
                    continue
                }

                guard case .scalar(let sv) = child.value else {
                    result[i].emptyCount += 1
                    continue
                }

                switch sv {
                case .null:
                    result[i].emptyCount += 1

                case .string(let s):
                    if s.isEmpty {
                        result[i].emptyCount += 1
                    } else {
                        result[i].stringCount += 1
                        if result[i].uniqueValues.count < 100 {
                            result[i].uniqueValues.insert(s)
                        }
                    }

                case .integer(let n):
                    result[i].intCount += 1
                    let d = Double(n)
                    result[i].numMin = min(result[i].numMin, d)
                    result[i].numMax = max(result[i].numMax, d)
                    if result[i].uniqueValues.count < 100 {
                        result[i].uniqueValues.insert(String(n))
                    }

                case .float(let f):
                    result[i].floatCount += 1
                    result[i].numMin = min(result[i].numMin, f)
                    result[i].numMax = max(result[i].numMax, f)
                    if result[i].uniqueValues.count < 100 {
                        result[i].uniqueValues.insert(String(f))
                    }

                case .boolean(let b):
                    result[i].stringCount += 1
                    if result[i].uniqueValues.count < 100 {
                        result[i].uniqueValues.insert(b ? "true" : "false")
                    }
                }
            }
        }

        return result
    }
}

// MARK: - ColumnStatCard

private struct ColumnStatCard: View {

    let stats: ColumnStats

    private var typeColor: Color {
        switch stats.detectedType {
        case "Integer", "Decimal": return .blue
        case "String":             return Color(red: 0.75, green: 0.3, blue: 0.1)
        case "Mixed":              return .orange
        default:                   return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // ── Column name + type badge ──────────────────────────────────
            HStack(alignment: .firstTextBaseline) {
                Text(stats.id)
                    .font(.system(.body, design: .monospaced).bold())
                Spacer()
                Text(stats.detectedType)
                    .font(.caption.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(typeColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(typeColor)
            }

            Divider()

            // ── Stats grid ────────────────────────────────────────────────
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow {
                    statCell(label: "Rows",    value: "\(stats.totalRows)")
                    statCell(label: "Non-empty", value: "\(stats.nonEmpty)")
                    statCell(label: "Empty",   value: "\(stats.emptyCount)")
                    statCell(label: "Unique",  value: stats.uniqueCount < 100
                             ? "\(stats.uniqueCount)"
                             : "100+")
                }

                if stats.hasNumericRange {
                    GridRow {
                        statCell(label: "Min", value: formatNum(stats.numMin))
                        statCell(label: "Max", value: formatNum(stats.numMax))
                        Color.clear.gridCellColumns(2)
                    }
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    private func formatNum(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 {
            return String(Int64(d))
        }
        return String(format: "%.4g", d)
    }
}
