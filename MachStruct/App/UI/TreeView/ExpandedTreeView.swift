import SwiftUI
import MachStructCore

// MARK: - FlatRow

/// A linearised record for a single visible tree row.
///
/// Produced by a DFS pre-order traversal of `TreeNode.children` that skips
/// nodes whose ancestors are not in `expandedIDs`.  The result is a flat
/// `[FlatRow]` array that drives `ExpandedTreeView`'s `List`.
struct FlatRow: Identifiable, Sendable {
    enum ID: Hashable, Sendable {
        case node(NodeID)
        case range(ChildRange)
    }
    enum Content: Sendable {
        case node(TreeNode)
        case range(ChildRange)
    }

    let id: ID
    let content: Content
    /// Visual indent level; increases by 1 for each expansion level.
    let indentLevel: Int
    /// `true` for ranges, and when `treeNode.children != nil` (including
    /// empty containers).
    let isExpandable: Bool

    /// The node shown, or `nil` for a range row.
    var treeNode: TreeNode? {
        if case .node(let node) = content { return node }
        return nil
    }
}

/// Children `bounds` of the row `parent`, collapsed into one row because the
/// container has too many to list (`ChildRanges`). `parent` is the row's node:
/// a `.keyValue` for a value shown on its key's row, the root at top level.
struct ChildRange: Hashable, Sendable {
    let parent: NodeID
    let bounds: Range<Int>
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

    /// Called with a node ID just before it is inserted into `expandedIDs`.
    /// Used by `ContentView` to trigger lazy materialisation of that node's
    /// children when the document was loaded with a shallow NodeIndex.
    var onExpand: ((NodeID) async -> Void)? = nil

    /// User preference (A4): when true, a primary click anywhere on an
    /// expandable row toggles its expansion. The chevron button always works
    /// regardless of this setting.
    @AppStorage(AppSettings.Keys.singleClickExpand)
    private var singleClickExpand = AppSettings.Defaults.singleClickExpand

    /// Cached flat-row array.  Recomputed only when `expandedIDs` or
    /// `nodeIndex.generation` changes — not on every SwiftUI body evaluation
    /// (which also fires on selection changes, scroll triggers, etc.).
    @State private var cachedFlatRows: [FlatRow] = []

    /// In-flight rebuild task.  Cancelled and replaced whenever `expandedIDs`
    /// or `nodeIndex.generation` changes so rapid toggles don't pile up work.
    @State private var rebuildTask: Task<Void, Never>? = nil

    /// Open range rows. Local to the tree: nothing outside needs them.
    @State private var expandedRanges: Set<ChildRange> = []

    /// A node the host asked to scroll to. Rebuilds open the ranges it lies
    /// in until it is listed, then scroll to it.
    @State private var revealTarget: NodeID? = nil
    /// Bumped to scroll to `scrollRow` once it is in the list.
    @State private var scrollRequest = 0
    @State private var scrollRow: NodeID? = nil

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(cachedFlatRows) { row in
                    selectableRow(row)
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
            .accessibilityLabel("Document tree")
            .onAppear { rebuildFlatRows() }
            .onChange(of: expandedIDs) { _, _ in rebuildFlatRows() }
            // Watch `generation` instead of `count` so that value edits
            // (which don't change the node count) also refresh the rows.
            .onChange(of: nodeIndex.generation) { _, _ in rebuildFlatRows() }
            .onChange(of: scrollTrigger) { _, _ in
                guard let id = scrollTarget else { return }
                // The row may be in a closed range, or not built yet: the
                // rebuild opens its ranges and scrolls once it is listed.
                revealTarget = id
                rebuildFlatRows()
            }
            .onChange(of: scrollRequest) { _, _ in
                guard let id = scrollRow else { return }
                // One async hop lets SwiftUI insert newly-expanded rows into
                // the List before we ask the ScrollViewReader to seek.
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(FlatRow.ID.node(id), anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Flat row computation

    /// Schedule an async rebuild of the flat-row cache.
    ///
    /// The heavy DFS walk is dispatched to a background thread so that expanding
    /// a node with tens of thousands of children never blocks the main actor.
    /// Any in-flight rebuild is cancelled before a new one begins, so rapid
    /// expand/collapse toggles or edits coalesce into a single update.
    private func rebuildFlatRows() {
        rebuildTask?.cancel()
        let builder = RowBuilder(nodeIndex: nodeIndex, expandedIDs: expandedIDs,
                                 expandedRanges: expandedRanges, reveal: revealTarget)

        rebuildTask = Task {
            let built = await Task.detached(priority: .userInitiated) {
                var builder = builder
                builder.build()
                return builder
            }.value

            guard !Task.isCancelled else { return }
            cachedFlatRows = built.rows
            expandedRanges.formUnion(built.openedRanges)
            if let target = revealTarget,
               built.rows.contains(where: { $0.id == .node(target) }) {
                revealTarget = nil
                scrollRow = target
                scrollRequest += 1
            }
        }
    }

    /// Computes the visible flat-row array from `nodeIndex`, `expandedIDs` and
    /// the open ranges. A value type so it can run in a `Task.detached`
    /// closure without capturing `self` (a mutable SwiftUI view struct).
    private struct RowBuilder: Sendable {
        let nodeIndex: NodeIndex
        let expandedIDs: Set<NodeID>
        let expandedRanges: Set<ChildRange>
        /// `reveal` and its ancestors: ranges holding one of them are opened.
        let revealPath: Set<NodeID>

        private(set) var rows: [FlatRow] = []
        /// Ranges opened to reveal the target, to be kept open.
        private(set) var openedRanges: Set<ChildRange> = []

        init(nodeIndex: NodeIndex, expandedIDs: Set<NodeID>,
             expandedRanges: Set<ChildRange>, reveal: NodeID?) {
            self.nodeIndex = nodeIndex
            self.expandedIDs = expandedIDs
            self.expandedRanges = expandedRanges
            self.revealPath = reveal.map { Set(nodeIndex.path(to: $0)) } ?? []
        }

        mutating func build() {
            let roots = ExpandedTreeView.rootTreeNodes(for: nodeIndex)
            appendChildren(roots, of: nodeIndex.rootID, in: roots.indices, level: 0)
        }

        /// DFS pre-order walk: append `treeNode`, then its children if it is
        /// both expandable and currently open.
        private mutating func appendRows(treeNode: TreeNode, level: Int) {
            let kids = treeNode.children   // [TreeNode]?
            rows.append(FlatRow(id: .node(treeNode.id), content: .node(treeNode),
                                indentLevel: level, isExpandable: kids != nil))
            if let kids, expandedIDs.contains(treeNode.id) {
                appendChildren(kids, of: treeNode.id, in: kids.indices, level: level + 1)
            }
        }

        /// The children at `bounds`, or range rows for them when there are
        /// too many to list.
        private mutating func appendChildren(_ kids: [TreeNode], of parent: NodeID,
                                             in bounds: Range<Int>, level: Int) {
            guard let groups = ChildRanges.groups(of: bounds) else {
                for kid in kids[bounds] { appendRows(treeNode: kid, level: level) }
                return
            }
            for group in groups {
                let range = ChildRange(parent: parent, bounds: group)
                rows.append(FlatRow(id: .range(range), content: .range(range),
                                    indentLevel: level, isExpandable: true))
                var isOpen = expandedRanges.contains(range)
                if !isOpen, !revealPath.isEmpty,
                   kids[group].contains(where: { revealPath.contains($0.id) }) {
                    isOpen = true
                    openedRanges.insert(range)
                }
                if isOpen { appendChildren(kids, of: parent, in: group, level: level + 1) }
            }
        }
    }

    /// Top-level `TreeNode`s to seed the traversal — mirrors `TreeView.rootRows`.
    ///
    /// Root objects/arrays are unwrapped so users see content immediately without
    /// having to expand an extra level.
    private static func rootTreeNodes(for nodeIndex: NodeIndex) -> [TreeNode] {
        guard let root = nodeIndex.root else { return [] }
        if root.type == .object || root.type == .array {
            return TreeNode.rows(for: root, in: nodeIndex)
        }
        return [TreeNode(documentNode: root, nodeIndex: nodeIndex)]
    }

    // MARK: - Row view

    /// Node rows are tagged for selection; range rows can't be selected.
    @ViewBuilder
    private func selectableRow(_ row: FlatRow) -> some View {
        switch row.content {
        case .node(let node):
            rowView(node, isExpandable: row.isExpandable).tag(node.id)
        case .range(let range):
            rangeRowView(range).selectionDisabled()
        }
    }

    @ViewBuilder
    private func rowView(_ node: TreeNode, isExpandable: Bool) -> some View {
        HStack(spacing: 4) {
            if isExpandable {
                disclosureButton(isOpen: expandedIDs.contains(node.id)) {
                    toggleExpanded(node.id)
                }
            } else {
                // Leaf node — reserve the same width so content stays aligned.
                Spacer().frame(width: 14)
            }

            // Body of the row.  `simultaneousGesture` lets the inner editing
            // gestures (key double-click rename, scalar tap-to-edit) keep
            // firing while still letting a primary click anywhere else on an
            // expandable row toggle expansion (A4).
            NodeRow(node: node)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture(count: 1).onEnded { _ in
                        guard isExpandable, singleClickExpand else { return }
                        toggleExpanded(node.id)
                    }
                )
        }
    }

    private func rangeRowView(_ range: ChildRange) -> some View {
        HStack(spacing: 4) {
            disclosureButton(isOpen: expandedRanges.contains(range)) { toggleRange(range) }
            // Verbatim: indices, not quantities, so no digit grouping.
            Text(verbatim: "[\(range.bounds.lowerBound) … \(range.bounds.upperBound - 1)]")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Items \(range.bounds.lowerBound) to \(range.bounds.upperBound - 1)")
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleRange(range) }
    }

    /// Manually drawn disclosure triangle.  Rotates 90° when open.
    private func disclosureButton(isOpen: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .animation(.easeInOut(duration: 0.15), value: isOpen)
                .frame(width: 14, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel(isOpen ? "Collapse" : "Expand")
    }

    private func toggleRange(_ range: ChildRange) {
        if expandedRanges.contains(range) {
            expandedRanges.remove(range)
        } else {
            expandedRanges.insert(range)
        }
        rebuildFlatRows()
    }

    private func toggleExpanded(_ id: NodeID) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else if let onExpand {
            // Materialise children on a background thread before revealing them.
            // The Task runs on the main actor after the await so expandedIDs
            // is updated in the same synchronous continuation as nodeIndex,
            // letting SwiftUI coalesce both state changes into one re-render.
            Task {
                await onExpand(id)
                expandedIDs.insert(id)
            }
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
        guard let parentID = row.treeNode?.documentNode.parentID,
              let parent   = nodeIndex.node(for: parentID) else { return false }
        return parent.type == .array
    }

    /// Translates a SwiftUI `.onMove` callback (which works in flat-array
    /// coordinates) into a parent-relative sibling index move, then dispatches
    /// an `EditTransaction` through the injected `commitEdit` closure.
    ///
    /// `flatRows` contains rows from *all* depths interleaved, and in a large
    /// container only the siblings in open ranges; `ChildRanges.moveDestination`
    /// maps the drop point to a child index.
    private func handleDragMove(from source: IndexSet, to destination: Int) {
        guard let fromFlatIdx = source.first,
              let sourceNode = cachedFlatRows[fromFlatIdx].treeNode,
              let parentID = sourceNode.documentNode.parentID,
              let parent   = nodeIndex.node(for: parentID),
              parent.type == .array,
              let fromIndex = parent.childIDs.firstIndex(of: sourceNode.id)
        else { return }

        // Range rows name the row the children appear under: the key's row
        // for a value shown on its key, the parent itself otherwise.
        let rowParent = parent.parentID.flatMap { nodeIndex.node(for: $0) }
            .flatMap { $0.type == .keyValue ? $0.id : nil } ?? parentID
        let position = Dictionary(uniqueKeysWithValues:
            parent.childIDs.enumerated().map { ($1, $0) })

        var siblings: [ChildRanges.VisibleSibling] = []
        var rangeRows: [Int] = []
        for (i, row) in cachedFlatRows.enumerated() where i != fromFlatIdx {
            switch row.content {
            case .node(let node):
                if node.documentNode.parentID == parentID, let child = position[node.id] {
                    siblings.append(.init(row: i, child: child))
                }
            case .range(let range):
                if range.parent == rowParent { rangeRows.append(i) }
            }
        }

        guard let toIndex = ChildRanges.moveDestination(from: fromIndex, droppedAt: destination,
                                                        siblings: siblings, rangeRows: rangeRows),
              fromIndex != toIndex,
              let tx = EditTransaction.moveArrayItem(
                  in: parentID,
                  fromIndex: fromIndex,
                  toIndex: toIndex,
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
