import SwiftUI
import MachStructCore

// MARK: - CSVStatsPanel

/// Sheet view showing per-column statistics for a tabular (CSV) document.
struct CSVStatsPanel: View {

    /// The statistics, computed in the background from the whole document.
    let load: () async -> [ColumnStats]

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
        stats = await load()
        isLoading = false
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
