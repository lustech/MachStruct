import Foundation

// MARK: - ChildRanges

/// Splits a container's children into ranges, the way browser dev tools show
/// `[0 … 99]`, so the tree never lists more than a page of rows at one level.
///
/// SwiftUI's `List` diffs every row on each update; a CSV file's 400 000 rows
/// at the top level froze the window for tens of seconds.
public enum ChildRanges {

    /// The most rows shown at one level, children or ranges.
    public static let pageSize = 1000

    /// The ranges to show for the children at `range`, or `nil` when there are
    /// few enough to list directly. Ranges are a page long while that gives at
    /// most a page of them, and grow a page-fold at a time beyond that, so an
    /// opened range splits again.
    public static func groups(of range: Range<Int>) -> [Range<Int>]? {
        guard range.count > pageSize else { return nil }
        var span = pageSize
        while range.count > span * pageSize { span *= pageSize }
        return stride(from: range.lowerBound, to: range.upperBound, by: span).map {
            $0..<min($0 + span, range.upperBound)
        }
    }

    // MARK: - Drag-and-drop

    /// A listed sibling of a dragged row: its position in the list, and its
    /// index among the parent's children.
    public struct VisibleSibling: Sendable {
        public let row: Int
        public let child: Int

        public init(row: Int, child: Int) {
            self.row = row
            self.child = child
        }
    }

    /// The child index a row dragged from child `from` and dropped at list
    /// position `droppedAt` moves to, or `nil` when the drop names no place.
    ///
    /// `siblings` are the parent's other listed children, in list order, and
    /// `rangeRows` the list positions of the parent's range rows. The row goes
    /// after the nearest sibling above the drop, or before the nearest one
    /// below it, whichever no range row separates from the drop point: in a
    /// split container the siblings either side may be ranges apart.
    public static func moveDestination(from: Int, droppedAt destination: Int,
                                       siblings: [VisibleSibling],
                                       rangeRows: [Int]) -> Int? {
        func rangeRow(in rows: Range<Int>) -> Bool {
            rangeRows.contains { rows.contains($0) }
        }
        // The child index the row goes in front of, before it is removed.
        let insertBefore: Int
        if let above = siblings.last(where: { $0.row < destination }),
           !rangeRow(in: above.row + 1..<max(above.row + 1, destination)) {
            insertBefore = above.child + 1
        } else if let below = siblings.first(where: { $0.row >= destination }),
                  !rangeRow(in: destination..<below.row) {
            insertBefore = below.child
        } else {
            return nil
        }
        return insertBefore > from ? insertBefore - 1 : insertBefore
    }
}
