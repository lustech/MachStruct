import SwiftUI
import MachStructCore

// MARK: - FlatRow

/// A linearised record for a single visible tree row.
///
/// Produced by a DFS pre-order traversal of `TreeNode.children` that skips
/// nodes whose ancestors are not in `expandedIDs`.  The result is a flat
/// `[FlatRow]` array that drives `ExpandedTreeView`'s `List`.
struct FlatRow: Identifiable {
    /// Same as `TreeNode.id` — interchangeable with `NodeID` used elsewhere.
    let id: NodeID
    let treeNode: TreeNode
    /// Visual indent level; increases by 1 for each expansion level.
    let indentLevel: Int
    /// `true` when `treeNode.children != nil` (including empty containers).
    let isExpandable: Bool
}

// MARK: - ExpandedTreeView

/// An expandable document tree with **programmatic expansion support** (P4-02).
///
/// ### Why not `List(data:children:selection:)`?
///
/// SwiftUI's built-in outline `List` owns its expand/collapse state internally
/// and exposes no API to open a specific node programmatically.  When the user
/// navigates to a search match inside a collapsed subtree (P4-02), the host
/// must be able to force-expand the ancestor chain.
///
/// ### Approach
///
/// `expandedIDs` is an external `@Binding` owned by `ContentView`.  A flat
/// `[FlatRow]` array is recomputed from the `NodeIndex` each time `expandedIDs`
/// changes; only visible rows are in the array, so collapsed subtrees have zero
/// rendering cost.  A `ScrollViewReader` + `scrollTrigger` counter lets the
/// host scroll any row into view after expansion.
struct ExpandedTreeView: View {

    let nodeIndex: NodeIndex

    /// Selection is owned by `ContentView` so the `StatusBar` can observe it.
    @Binding var selection: NodeID?

    /// IDs of nodes whose children are currently shown.
    @Binding var expandedIDs: Set<NodeID>

    /// Injected by `ContentView` — commits an edit transaction with undo support.
    @Environment(\.commitEdit) private var commitEdit

    /// Incremented each time the host wants to scroll.  Using a counter (rather
    /// than comparing the target ID) ensures the scroll fires even when
    /// navigating back to a previously-visited match with the same ID.
    let scrollTrigger: Int

    /// Node to scroll into view when `scrollTrigger` increments.
    let scrollTarget: NodeID?

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(flatRows) { row in
                    rowView(row)
                        .tag(row.id)
                        .listRowInsets(EdgeInsets(
                            top:     1,
                            leading: CGFloat(row.indentLevel) * 18 + 6,
                            bottom:  1,
                            trailing: 8
                        ))
                        .moveDisabled(!isMovableRow(row))
                }
                .onMove { handleDragMove(from: $0, to: $1) }
            }
            .listStyle(.sidebar)
            .onChange(of: scrollTrigger) { _, _ in
                guard let id = scrollTarget else { return }
                // One async hop lets SwiftUI insert newly-expanded rows into
                // the List before we ask the ScrollViewReader to seek.
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Flat row computation

    private var flatRows: [FlatRow] {
        var result: [FlatRow] = []
        for root in rootTreeNodes {
            appendRows(treeNode: root, level: 0, into: &result)
        }
        return result
    }

    /// DFS pre-order walk: append `treeNode`, then recurse into children if
    /// the node is both expandable and currently open.
    private func appendRows(treeNode: TreeNode,
                            level: Int,
                            into result: inout [FlatRow]) {
        let kids         = treeNode.children   // [TreeNode]?
        let isExpandable = (kids != nil)

        result.append(FlatRow(
            id:           treeNode.id,
            treeNode:     treeNode,
            indentLevel:  level,
            isExpandable: isExpandable
        ))

        if isExpandable,
           expandedIDs.contains(treeNode.id),
           let kids {
            for kid in kids {
                appendRows(treeNode: kid, level: level + 1, into: &result)
            }
        }
    }

    /// Top-level `TreeNode`s to seed the traversal — mirrors `TreeView.rootRows`.
    ///
    /// Root objects/arrays are unwrapped so users see content immediately without
    /// having to expand an extra level.
    private var rootTreeNodes: [TreeNode] {
        guard let root = nodeIndex.root else { return [] }
        if root.type == .object || root.type == .array {
            return nodeIndex.children(of: nodeIndex.rootID)
                .map { TreeNode(documentNode: $0, nodeIndex: nodeIndex) }
        }
        return [TreeNode(documentNode: root, nodeIndex: nodeIndex)]
    }

    // MARK: - Row view

    @ViewBuilder
    private func rowView(_ row: FlatRow) -> some View {
        HStack(spacing: 4) {
            if row.isExpandable {
                // Manually drawn disclosure triangle.  Rotates 90° when open.
                Button { toggleExpanded(row.id) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(
                            expandedIDs.contains(row.id) ? 90 : 0
                        ))
                        .animation(.easeInOut(duration: 0.15),
                                   value: expandedIDs.contains(row.id))
                        .frame(width: 14, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            } else {
                // Leaf node — reserve the same width so content stays aligned.
                Spacer().frame(width: 14)
            }

            NodeRow(node: row.treeNode)
        }
    }

    private func toggleExpanded(_ id: NodeID) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }

    // MARK: - Drag-and-drop reordering (P4-05)

    /// Only rows whose parent is an `.array` node may be reordered via drag.
    /// Object key-value pairs have a defined order too, but reordering object
    /// keys is semantically ambiguous (JSON doesn't guarantee key order), so
    /// we restrict to arrays where index order is meaningful.
    private func isMovableRow(_ row: FlatRow) -> Bool {
        guard let parentID = row.treeNode.documentNode.parentID,
              let parent   = nodeIndex.node(for: parentID) else { return false }
        return parent.type == .array
    }

    /// Translates a SwiftUI `.onMove` callback (which works in flat-array
    /// coordinates) into a parent-relative sibling index move, then dispatches
    /// an `EditTransaction` through the injected `commitEdit` closure.
    ///
    /// ### Index translation
    ///
    /// `flatRows` contains rows from *all* depths interleaved.  When the user
    /// drags row at `fromFlatIdx` to `destination`, we need sibling positions
    /// within the parent array — not flat positions.  We:
    ///
    /// 1. Collect the flat indices of every sibling (same `parentID`).
    /// 2. Count how many of those sibling indices appear before `destination`
    ///    (excluding the source row itself) → that is `toSiblingPos`.
    private func handleDragMove(from source: IndexSet, to destination: Int) {
        guard let fromFlatIdx = source.first else { return }
        let sourceRow = flatRows[fromFlatIdx]

        guard let parentID = sourceRow.treeNode.documentNode.parentID,
              let parent   = nodeIndex.node(for: parentID),
              parent.type == .array else { return }

        // All flat indices that belong to direct children of the same parent.
        let siblingFlatIndices = flatRows.indices.filter {
            flatRows[$0].treeNode.documentNode.parentID == parentID
        }

        guard let fromSiblingPos = siblingFlatIndices.firstIndex(of: fromFlatIdx)
        else { return }

        // Count siblings whose flat index < destination, skipping the source.
        let toSiblingPos = siblingFlatIndices.filter {
            $0 != fromFlatIdx && $0 < destination
        }.count

        guard fromSiblingPos != toSiblingPos,
              let tx = EditTransaction.moveArrayItem(
                  in: parentID,
                  fromIndex: fromSiblingPos,
                  toIndex: toSiblingPos,
                  in: nodeIndex)
        else { return }

        commitEdit?(tx)
    }
}

// MARK: - Preview

#Preview {
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

    addScalar(key: "name",   value: .string("Alice"), parent: rootNode.id, pos: 0)
    addScalar(key: "age",    value: .integer(30),      parent: rootNode.id, pos: 1)
    addScalar(key: "active", value: .boolean(true),    parent: rootNode.id, pos: 2)

    return ExpandedTreeView(
        nodeIndex: idx,
        selection: .constant(nil),
        expandedIDs: .constant([]),
        scrollTrigger: 0,
        scrollTarget: nil
    )
    .frame(width: 500, height: 300)
}
