import SwiftUI
import AppKit
import MachStructCore

// MARK: - NodeRow

/// A single row in the document tree.
///
/// ## Editing interactions
/// - **Value** (P2-01): click the value label on a scalar row to enter edit mode.
///   Press Return to commit, Escape to cancel.  Type is auto-detected.
/// - **Key** (P2-02): double-click the key label on a keyValue row to rename it.
///   Press Return to commit, Escape to cancel.
/// - **Context menu** (P2-03): right-click any row for Add / Delete actions.
/// - **Move Up / Down** (P2-04): reorder items within an array via context menu.
/// - **Copy / Paste** (P2-08): copy node as JSON; paste JSON into containers.
struct NodeRow: View {

    let node: TreeNode

    // MARK: - Environment

    @Environment(\.commitEdit)   private var commitEdit
    @Environment(\.serializeNode) private var serializeNode

    // MARK: - Editing state

    @State private var editingField: EditField? = nil
    @State private var editText: String = ""
    @FocusState private var isFocused: Bool

    // MARK: - Format-specific helpers

    /// Non-nil when this row represents an XML element.
    private var xmlElementMeta: XMLMetadata? { node.xmlElementMeta }

    /// Tooltip text for a YAML scalar-style badge.
    private func yamlStyleHelp(_ style: BadgeStyle) -> String {
        switch style {
        case .yamlLiteral:  return "Literal block scalar ( | )"
        case .yamlFolded:   return "Folded block scalar ( > )"
        case .yamlSingleQ:  return "Single-quoted scalar"
        case .yamlDoubleQ:  return "Double-quoted scalar"
        default:            return ""
        }
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 6) {
            keyView
            valueView
            Spacer(minLength: 8)
            // Namespace badge — shown before the main type badge for namespaced XML elements.
            if let ns = xmlElementMeta?.namespace {
                TypeBadge(style: .ns)
                    .help(ns)   // full URI on hover
            }
            // YAML anchor badge — shown when the node declares a named anchor (&name).
            if node.hasYAMLAnchor, let anchor = node.yamlValueMeta?.anchor {
                TypeBadge(style: .yamlAnchor)
                    .help("Anchor: &\(anchor)")
            }
            // YAML scalar-style badge — shown for non-plain scalar styles (|, >, ', ").
            if let styleBadge = node.yamlStyleBadge {
                TypeBadge(style: styleBadge)
                    .help(yamlStyleHelp(styleBadge))
            }
            TypeBadge(style: node.badgeInfo.style)
        }
        .font(.system(.body, design: .monospaced))
        .contextMenu { contextMenuItems }
        .onChange(of: editingField) { _, newValue in
            isFocused = (newValue != nil)
        }
    }

    // MARK: - Key view (P2-02: double-click to rename)

    @ViewBuilder
    private var keyView: some View {
        if let key = node.displayKey {
            if xmlElementMeta != nil {
                // XML element: display as <tagName> in teal — no quotes, no colon.
                Text("<\(key)>")
                    .foregroundStyle(Color(red: 0.15, green: 0.60, blue: 0.55))
            } else if editingField == .key {
                TextField("Key", text: $editText)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit { commitKeyEdit() }
                    .onKeyPress(.escape) { cancelEdit(); return .handled }
                    .fixedSize()
            } else {
                Group {
                    if node.documentNode.type == .scalar,
                       node.nodeIndex.parent(of: node.id)?.type == .array {
                        Text("[\(key)]")
                    } else {
                        Text("\"\(key)\"")
                    }
                }
                .foregroundStyle(.secondary)
                .onTapGesture(count: 2) {
                    if node.documentNode.type == .keyValue { startKeyEdit(key) }
                }

                Text(":")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Value view (P2-01: single click to edit scalar)

    @ViewBuilder
    private var valueView: some View {
        let vn = node.valueNode
        if editingField == .value {
            TextField("Value", text: $editText)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { commitValueEdit() }
                .onKeyPress(.escape) { cancelEdit(); return .handled }
        } else {
            switch vn.value {
            case .scalar(let sv):
                Text(sv.displayText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(scalarColor(sv))
                    .onTapGesture { startValueEdit(sv) }

            case .container, .unparsed:
                Text(node.displayValue)
                    .foregroundStyle(.secondary)

            case .error(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Context menu (P2-03, P2-04, P2-08)

    @ViewBuilder
    private var contextMenuItems: some View {
        let vn = node.valueNode

        // Add children (P2-03)
        if vn.type == .object {
            Button("Add Key-Value") { addKeyValue(to: vn.id) }
        }
        if vn.type == .array {
            Button("Add Item") { addArrayItem(to: vn.id) }
        }

        // Move Up / Move Down within parent array (P2-04)
        if let (parentID, idx, count) = arrayItemInfo {
            Divider()
            Button("Move Up") {
                moveItem(fromIndex: idx, toIndex: idx - 1, in: parentID)
            }
            .disabled(idx == 0)

            Button("Move Down") {
                moveItem(fromIndex: idx, toIndex: idx + 1, in: parentID)
            }
            .disabled(idx == count - 1)
        }

        // Copy / Paste (P2-08)
        Divider()
        Button("Copy as JSON") { copyNodeAsJSON() }

        if vn.type == .object || vn.type == .array {
            Button("Paste from Clipboard") { pasteFromClipboard(into: vn.id) }
        }

        // Delete (P2-03)
        if canDelete {
            Divider()
            Button("Delete", role: .destructive) { deleteNode() }
        }
    }

    // MARK: - Helpers

    private var canDelete: Bool { node.documentNode.parentID != nil }

    /// Returns `(parentID, itemIndex, totalCount)` when this node is a direct
    /// child of an array — used to enable Move Up / Move Down.
    private var arrayItemInfo: (parentID: NodeID, index: Int, count: Int)? {
        guard let parentID = node.documentNode.parentID,
              let parent = node.nodeIndex.node(for: parentID),
              parent.type == .array,
              let idx = parent.childIDs.firstIndex(of: node.documentNode.id)
        else { return nil }
        return (parentID, idx, parent.childIDs.count)
    }

    private func scalarColor(_ sv: ScalarValue) -> Color {
        switch sv {
        case .string:          return Color(red: 0.8, green: 0.3, blue: 0.1)
        case .integer, .float: return .blue
        case .boolean:         return .orange
        case .null:            return .secondary
        }
    }

    private func rawText(for sv: ScalarValue) -> String {
        switch sv {
        case .string(let s):  return s
        case .integer(let i): return String(i)
        case .float(let f):   return String(f)
        case .boolean(let b): return b ? "true" : "false"
        case .null:           return "null"
        }
    }

    // MARK: - Edit lifecycle

    private func startValueEdit(_ sv: ScalarValue) {
        guard editingField == nil else { return }
        editText = rawText(for: sv)
        editingField = .value
    }

    private func startKeyEdit(_ key: String) {
        guard editingField == nil else { return }
        editText = key
        editingField = .key
    }

    private func cancelEdit() {
        editingField = nil
        editText = ""
    }

    // MARK: - Commit value (P2-01)

    private func commitValueEdit() {
        defer { cancelEdit() }
        let newScalar = parseScalarValue(editText)
        let newValue  = NodeValue.scalar(newScalar)
        let vn        = node.valueNode
        if case .scalar(let current) = vn.value, current == newScalar { return }
        let desc = "Change Value of '\(node.displayKey ?? "node")'"
        guard let tx = EditTransaction.changeValue(
            of: vn.id, to: newValue, description: desc,
            in: node.nodeIndex) else { return }
        commitEdit?(tx)
    }

    // MARK: - Commit key rename (P2-02)

    private func commitKeyEdit() {
        defer { cancelEdit() }
        let newKey = editText.trimmingCharacters(in: .whitespaces)
        guard !newKey.isEmpty, newKey != node.documentNode.key else { return }
        guard let tx = EditTransaction.renameKey(
            of: node.documentNode.id, to: newKey,
            in: node.nodeIndex) else { return }
        commitEdit?(tx)
    }

    // MARK: - Add / Delete (P2-03)

    private func addKeyValue(to containerID: NodeID) {
        guard let tx = EditTransaction.insertKeyValue(
            key: "newKey", value: .string("value"),
            into: containerID, in: node.nodeIndex) else { return }
        commitEdit?(tx)
    }

    private func addArrayItem(to containerID: NodeID) {
        guard let tx = EditTransaction.insertArrayItem(
            value: .string(""), into: containerID,
            in: node.nodeIndex) else { return }
        commitEdit?(tx)
    }

    private func deleteNode() {
        guard let tx = EditTransaction.removeNode(
            node.documentNode.id, in: node.nodeIndex) else { return }
        commitEdit?(tx)
    }

    // MARK: - Move Up / Down (P2-04)

    private func moveItem(fromIndex: Int, toIndex: Int, in parentID: NodeID) {
        guard let tx = EditTransaction.moveArrayItem(
            in: parentID, fromIndex: fromIndex, toIndex: toIndex,
            in: node.nodeIndex) else { return }
        commitEdit?(tx)
    }

    // MARK: - Copy / Paste (P2-08)

    private func copyNodeAsJSON() {
        let targetID = node.valueNode.id
        guard let data = serializeNode?(targetID, true),
              let json = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
    }

    private func pasteFromClipboard(into containerID: NodeID) {
        guard let text = NSPasteboard.general.string(forType: .string),
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data,
                                                           options: [.allowFragments])
        else { return }
        guard let tx = EditTransaction.insertFromClipboard(
            json, into: containerID, in: node.nodeIndex) else { return }
        commitEdit?(tx)
    }
}

// MARK: - EditField

private enum EditField: Equatable {
    case value, key
}

// MARK: - Preview

#Preview {
    let root = DocumentNode(type: .object, value: .container(childCount: 2))
    var index = NodeIndex(root: root)
    let strNode = DocumentNode(
        id: NodeID.generate(), type: .scalar, depth: 1,
        parentID: root.id, key: "name", value: .scalar(.string("Alice")))
    let numNode = DocumentNode(
        id: NodeID.generate(), type: .scalar, depth: 1,
        parentID: root.id, key: "age", value: .scalar(.integer(30)))
    index.insertChild(strNode, in: root.id, at: 0)
    index.insertChild(numNode, in: root.id, at: 1)

    let rows = [strNode, numNode].map { TreeNode(documentNode: $0, nodeIndex: index) }
    return List(rows, children: \.children) { row in NodeRow(node: row) }
        .frame(width: 400, height: 120)
        .environment(\.commitEdit) { _ in }
        .environment(\.serializeNode) { _, _ in nil }
}
