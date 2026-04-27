import SwiftUI
import MachStructCore

// MARK: - StatusBar

/// Thin bar at the bottom of the document window.
///
/// Shows four data points that update as the user navigates:
///   path: root.items[42].name   •   12,048 nodes   •   4.2 MB   •   JSON
struct StatusBar: View {

    let nodeIndex: NodeIndex
    let selectedID: NodeID?
    let fileSize: Int64
    let formatName: String

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            // Path — takes all available space; truncates in the middle.
            // Hover tooltip shows the full path so users can read long paths
            // without resizing the window.
            Text(pathText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .help(pathText)

            separator

            // Node count
            Text(nodeCountText)
                .padding(.horizontal, 10)
                .fixedSize()

            separator

            // File size
            Text(fileSizeText)
                .padding(.horizontal, 10)
                .fixedSize()

            separator

            // Format name
            Text(formatName)
                .padding(.horizontal, 10)
                .fixedSize()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(height: 22)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Status. Path: \(pathText). \(nodeCountText). Size: \(fileSizeText). Format: \(formatName)."
        )
    }

    // MARK: - Separator

    private var separator: some View {
        Divider()
            .frame(height: 12)
            .padding(.horizontal, 2)
    }

    // MARK: - Computed text

    private var pathText: String {
        guard let id = selectedID else { return String(localized: "No selection") }
        return nodeIndex.pathString(to: id)
    }

    private var nodeCountText: String {
        let n = nodeIndex.count
        let suffix = n == 1 ? String(localized: "node") : String(localized: "nodes")
        return "\(n.formatted()) \(suffix)"
    }

    private var fileSizeText: String {
        guard fileSize > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: fileSize,
                                         countStyle: .file)
    }
}

// MARK: - Preview

#Preview {
    // Build a small index for the preview.
    let root = DocumentNode(type: .object, value: .container(childCount: 1))
    let child = DocumentNode(
        id: NodeID.generate(), type: .keyValue, depth: 1,
        parentID: root.id, key: "name", value: .unparsed)
    var idx = NodeIndex(root: root)
    idx.insertChild(child, in: root.id, at: 0)

    return StatusBar(
        nodeIndex: idx,
        selectedID: child.id,
        fileSize: 4_398_046,
        formatName: "JSON"
    )
    .frame(width: 700)
}
