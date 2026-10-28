import SwiftUI
import AppKit
import MachStructCore

// MARK: - TableView

/// Spreadsheet-style table for documents whose root is a uniform array of objects.
///
/// Backed by `NSTableView`, which asks only for the rows on screen: a SwiftUI
/// stack built a view per row up front, so a 400 000-row CSV froze the window
/// for 18 seconds and used 1.8 GB before showing anything (#56).
///
/// Columns come from `NodeIndex.tabularColumns`. In a large file a row's cells
/// exist only once loaded, so the table reports the rows it shows through
/// `loadRows` and fills them in when they arrive.
///
/// ## Selection
/// Clicking a row sets `selection` to the row's object `NodeID`, keeping it
/// in sync with the tree view's selection binding.
struct TableView: NSViewRepresentable {

    let nodeIndex: NodeIndex
    @Binding var selection: NodeID?
    /// Loads the cells of the given rows, if they aren't loaded yet. The set
    /// is every row on screen, so loading can keep them all in memory.
    var loadRows: ((Set<NodeID>) async -> Void)? = nil

    @AppStorage(AppSettings.Keys.colorTheme) private var colorTheme = ColorTheme.standard

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .plain
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.setAccessibilityLabel("Table")
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        context.coordinator.table = table
        context.coordinator.observeScrolling(of: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(nodeIndex: nodeIndex, selection: $selection,
                                   loadRows: loadRows, theme: colorTheme)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {

        weak var table: NSTableView?
        private var nodeIndex = NodeIndex(root: DocumentNode(type: .array))
        private var rowIDs: [NodeID] = []
        private var columns: [String] = []
        private var generation: UInt64?
        private var selection: Binding<NodeID?> = .constant(nil)
        private var loadRows: ((Set<NodeID>) async -> Void)?
        private var loadTask: Task<Void, Never>?
        /// Set while the table's selection is changed to match `selection`,
        /// so the change isn't reported back.
        private var isSyncingSelection = false
        private var theme = ColorTheme.standard

        private static let columnWidth: CGFloat = 160

        func update(nodeIndex: NodeIndex, selection: Binding<NodeID?>,
                    loadRows: ((Set<NodeID>) async -> Void)?, theme: ColorTheme) {
            self.selection = selection
            self.loadRows = loadRows
            guard let table else { return }

            if theme != self.theme {
                self.theme = theme
                table.reloadData()
            }

            if generation != nodeIndex.generation {
                generation = nodeIndex.generation
                self.nodeIndex = nodeIndex
                rowIDs = nodeIndex.root?.childIDs ?? []
                let newColumns = nodeIndex.tabularColumns
                if newColumns != columns {
                    columns = newColumns
                    rebuildColumns(of: table)
                }
                table.reloadData()
                scheduleLoad()
            }
            syncSelection(of: table)
        }

        private func rebuildColumns(of table: NSTableView) {
            for column in table.tableColumns { table.removeTableColumn(column) }
            for (i, name) in columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(i)"))
                column.title = name
                column.width = Self.columnWidth
                column.minWidth = 40
                column.headerCell.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
                table.addTableColumn(column)
            }
        }

        private func syncSelection(of table: NSTableView) {
            let wanted = selection.wrappedValue.flatMap { id in rowIDs.firstIndex(of: id) }
            guard table.selectedRow != (wanted ?? -1) else { return }
            isSyncingSelection = true
            if let wanted {
                table.selectRowIndexes([wanted], byExtendingSelection: false)
                table.scrollRowToVisible(wanted)
            } else {
                table.deselectAll(nil)
            }
            isSyncingSelection = false
        }

        // MARK: Loading rows as they scroll into view

        func observeScrolling(of clip: NSClipView) {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsDidChange),
                name: NSView.boundsDidChangeNotification, object: clip)
        }

        @objc private func boundsDidChange(_ note: Notification) { scheduleLoad() }

        /// Ask for the rows on screen once scrolling pauses. The first row is
        /// always included: the column names come from it.
        private func scheduleLoad() {
            guard let loadRows, let table, !rowIDs.isEmpty else { return }
            loadTask?.cancel()
            loadTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(30))
                guard let self, !Task.isCancelled else { return }
                let visible = table.rows(in: table.visibleRect)
                var ids: Set<NodeID> = [self.rowIDs[0]]
                let upper = min(visible.location + visible.length, self.rowIDs.count)
                if visible.location < upper {
                    ids.formUnion(self.rowIDs[visible.location..<upper])
                }
                await loadRows(ids)
            }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { rowIDs.count }

        // MARK: Delegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let tableColumn, let col = Int(tableColumn.identifier.rawValue),
                  columns.indices.contains(col), rowIDs.indices.contains(row) else { return nil }

            let id = NSUserInterfaceItemIdentifier("cell")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
                ?? Self.makeCell(identifier: id)
            let value = scalarValue(row: rowIDs[row], column: columns[col])
            cell.textField?.stringValue = value?.displayText ?? ""
            cell.textField?.textColor = value.map(theme.nsColor(for:)) ?? theme.nsColor(\.muted)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let table else { return }
            let row = table.selectedRow
            selection.wrappedValue = rowIDs.indices.contains(row) ? rowIDs[row] : nil
        }

        // MARK: Cells

        private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        /// The scalar under `column` in the row, or `nil` when the row has no
        /// such cell or hasn't been loaded yet.
        private func scalarValue(row: NodeID, column: String) -> ScalarValue? {
            guard let kv = nodeIndex.children(of: row).first(where: { $0.key == column }),
                  let scalar = nodeIndex.children(of: kv.id).first,
                  case .scalar(let sv) = scalar.value else { return nil }
            return sv
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
