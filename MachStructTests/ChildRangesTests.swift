import XCTest
@testable import MachStructCore

/// A container with more children than fit in one page is shown as range rows,
/// so the tree never lists more than a page of rows at any level.
final class ChildRangesTests: XCTestCase {

    func testAPageOrLessIsListedDirectly() {
        XCTAssertNil(ChildRanges.groups(of: 0..<0))
        XCTAssertNil(ChildRanges.groups(of: 0..<1000))
    }

    func testOneMoreThanAPageSplitsIntoTwoRanges() {
        XCTAssertEqual(ChildRanges.groups(of: 0..<1001), [0..<1000, 1000..<1001])
    }

    func testRangesArePagesWhileTheyFitInAPage() {
        let groups = try? XCTUnwrap(ChildRanges.groups(of: 0..<400_000))
        XCTAssertEqual(groups?.count, 400)
        XCTAssertEqual(groups?.first, 0..<1000)
        XCTAssertEqual(groups?.last, 399_000..<400_000)
    }

    func testRangesGrowSoThereAreNeverMoreThanAPageOfThem() {
        XCTAssertEqual(ChildRanges.groups(of: 0..<2_500_000),
                       [0..<1_000_000, 1_000_000..<2_000_000, 2_000_000..<2_500_000])
    }

    func testAnOpenedRangeSplitsAgain() {
        let inner = try? XCTUnwrap(ChildRanges.groups(of: 1_000_000..<2_000_000))
        XCTAssertEqual(inner?.count, 1000)
        XCTAssertEqual(inner?.first, 1_000_000..<1_001_000)
    }
}

// MARK: - Drag-and-drop between ranges

final class ChildRangesMoveTests: XCTestCase {

    private typealias Sibling = ChildRanges.VisibleSibling

    /// Without ranges every sibling is listed, and the result must match the
    /// rule used before ranges existed: the number of other siblings above the
    /// drop point.
    func testWithoutRangesMatchesCountingSiblingsAboveTheDrop() {
        let n = 6
        for from in 0..<n {
            for destination in 0...n {
                let siblings = (0..<n).filter { $0 != from }.map { Sibling(row: $0, child: $0) }
                let expected = (0..<n).filter { $0 != from && $0 < destination }.count
                XCTAssertEqual(ChildRanges.moveDestination(from: from, droppedAt: destination,
                                                           siblings: siblings, rangeRows: []),
                               expected, "from \(from) to \(destination)")
            }
        }
    }

    /// Rows: 0 `[0 … 999]` (closed), 1 `[1000 … 1499]` (open), 2… children
    /// 1000…, so child c sits at row c - 998.
    private func openSecondRange(movingChild from: Int) -> [Sibling] {
        (1000..<1500).filter { $0 != from }.map { Sibling(row: $0 - 998, child: $0) }
    }

    func testDropInsideAnOpenRangeUsesRealIndices() {
        // 1002 (row 4) dropped above 1006 (row 8) lands after 1005.
        XCTAssertEqual(ChildRanges.moveDestination(from: 1002, droppedAt: 8,
                                                   siblings: openSecondRange(movingChild: 1002),
                                                   rangeRows: [0, 1]), 1005)
    }

    func testDropJustBelowARangeRowGoesToTheStartOfThatRange() {
        // 1010 dropped at row 2, right under the open range's header.
        XCTAssertEqual(ChildRanges.moveDestination(from: 1010, droppedAt: 2,
                                                   siblings: openSecondRange(movingChild: 1010),
                                                   rangeRows: [0, 1]), 1000)
    }

    func testDropBetweenClosedRangesIsIgnored() {
        // Rows: 0 `[0 … 999]` open with children 0…999 at rows 1…1000,
        // 1001 `[1000 … 1999]` closed, 1002 `[2000 … 2499]` closed.
        let siblings = (1..<1000).map { Sibling(row: $0 + 1, child: $0) }
        XCTAssertNil(ChildRanges.moveDestination(from: 0, droppedAt: 1002,
                                                 siblings: siblings, rangeRows: [0, 1001, 1002]))
    }
}
