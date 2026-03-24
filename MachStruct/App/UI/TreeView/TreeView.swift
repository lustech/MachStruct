import SwiftUI
import MachStructCore

// MARK: - TreeView

/// The primary document view: a lazy, expandable outline of every node.
///
/// Uses `List(data:children:)` which gives us:
///   • Automatic view recycling — only visible rows are in memory.
///   • Native macOS disclosure arrows with keyboard navigation.
///   • Zero-cost collapsed subtrees — unexpanded nodes never touch their children.
struct TreeView: View {

    let nodeIndex: NodeIndex

    /// Selection is owned by the parent (ContentView) so the StatusBar can observe it.
    @Binding var selection: NodeID?

    // MARK: - Body

    var body: some View {
        List(rootRows, children: \.children, selection: $selection) { node in
            NodeRow(node: node)
                .tag(node.id)
        }
        .listStyle(.sidebar)
    }

    // MARK: - Root rows

    /// Top-level rows to seed the `List`.
    ///
    /// - If the root is an object or array, show its children directly so the
    ///   user sees content immediately without having to expand one extra level.
    /// - Otherwise (scalar root, e.g. a bare JSON number) show the root itself.
    private var rootRows: [TreeNode] {
        guard let root = nodeIndex.root else { return [] }

        if root.type == .object || root.type == .array {
            return nodeIndex.children(of: nodeIndex.rootID)
                .map { TreeNode(documentNode: $0, nodeIndex: nodeIndex) }
        }

        return [TreeNode(documentNode: root, nodeIndex: nodeIndex)]
    }
}

#Preview {
    // Build a small sample document for the preview canvas.
    let rootNode = DocumentNode(type: .object, value: .container(childCount: 3))
    var idx = NodeIndex(root: rootNode)

    func addScalar(key: String, value: ScalarValue, parent: NodeID, pos: Int) {
        var kv = DocumentNode(
            id: NodeID.generate(), type: .keyValue, depth: 1,
            parentID: parent, key: key, value: .unparsed)
        let scalar = DocumentNode(
            id: NodeID.generate(), type: .scalar, depth: 2,
            parentID: kv.id, value: .scalar(value))
        idx.insertChild(kv, in: parent, at: pos)
        kv.childIDs = [scalar.id]
        idx.insert(kv)
        idx.insertChild(scalar, in: kv.id, at: 0)
    }

    addScalar(key: "name",   value: .string("Alice"),  parent: rootNode.id, pos: 0)
    addScalar(key: "age",    value: .integer(30),       parent: rootNode.id, pos: 1)
    addScalar(key: "active", value: .boolean(true),     parent: rootNode.id, pos: 2)

    return TreeView(nodeIndex: idx, selection: .constant(nil))
        .frame(width: 500, height: 300)
}
