import SwiftUI
import MachStructCore

// MARK: - NodeRow

/// A single row in the document tree.
///
/// Layout (left → right):
///   [key in muted text]  [colon separator]  [value, truncated]  [Spacer]  [TypeBadge]
///
/// Examples:
///   "name"  :  "John Doe"                                          str
///   "count"  :  42                                                  int
///   "items"  :  [3 items]                                           arr
///   [0]  :  "first"                                                str
struct NodeRow: View {

    let node: TreeNode

    var body: some View {
        HStack(spacing: 6) {
            keyView
            valueView
            Spacer(minLength: 8)
            TypeBadge(style: node.badgeInfo.style)
        }
        .font(.system(.body, design: .monospaced))
    }

    // MARK: - Key

    @ViewBuilder
    private var keyView: some View {
        if let key = node.displayKey {
            Group {
                // Array indices like "0", "1" use bracket notation.
                if node.documentNode.type == .scalar,
                   node.nodeIndex.parent(of: node.id)?.type == .array {
                    Text("[\(key)]")
                } else {
                    Text("\"\(key)\"")
                }
            }
            .foregroundStyle(.secondary)

            Text(":")
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Value

    @ViewBuilder
    private var valueView: some View {
        let vn = node.valueNode
        switch vn.value {
        case .scalar(let sv):
            Text(sv.displayText)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(scalarColor(sv))

        case .container, .unparsed:
            Text(node.displayValue)
                .foregroundStyle(.secondary)

        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    // MARK: - Scalar color

    private func scalarColor(_ sv: ScalarValue) -> Color {
        switch sv {
        case .string:        return Color(red: 0.8, green: 0.3, blue: 0.1)   // warm red-orange
        case .integer, .float: return .blue
        case .boolean:       return .orange
        case .null:          return .secondary
        }
    }
}

#Preview {
    // Construct a tiny NodeIndex for preview purposes.
    let root = DocumentNode(type: .object, value: .container(childCount: 2))
    var index = NodeIndex(root: root)
    let strNode = DocumentNode(
        id: NodeID.generate(),
        type: .scalar, depth: 1,
        parentID: root.id,
        key: "name",
        value: .scalar(.string("Alice")))
    let numNode = DocumentNode(
        id: NodeID.generate(),
        type: .scalar, depth: 1,
        parentID: root.id,
        key: "age",
        value: .scalar(.integer(30)))
    index.insertChild(strNode, in: root.id, at: 0)
    index.insertChild(numNode, in: root.id, at: 1)

    let rows = [strNode, numNode].map { dn in
        TreeNode(documentNode: dn, nodeIndex: index)
    }
    return List(rows, children: \.children) { row in
        NodeRow(node: row)
    }
    .frame(width: 400, height: 120)
}
