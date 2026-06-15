import XCTest
@testable import MachStructCore

// MARK: - Batch EditTransaction factories

final class BatchEditTransactionTests: XCTestCase {

    private func index(from value: JQValue) -> NodeIndex {
        let built = value.toDocumentNodes(parentID: nil, depth: 0, key: nil)
        return NodeIndex(rootID: built.root, allNodes: built.nodes)
    }

    private func obj(_ pairs: [(String, JQValue)]) -> JQValue { .object(pairs.map { ($0.0, $0.1) }) }

    // MARK: batchSetValue

    func testBatchSetValueAppliesToAllAndIsOneTransaction() {
        var idx = index(from: .array([.int(1), .int(2), .int(3)]))
        let scalarIDs = idx.children(of: idx.rootID).map { $0.id }

        let tx = EditTransaction.batchSetValue(ofScalars: scalarIDs, to: .integer(0),
                                               description: "Zero out", in: idx)
        let tx2 = try? XCTUnwrap(tx)
        guard let tx2 else { return XCTFail("expected a transaction") }

        idx = tx2.applying(to: idx)
        XCTAssertEqual(idx.children(of: idx.rootID).map { JQValue(node: $0.id, in: idx) },
                       [.int(0), .int(0), .int(0)])

        // Single undo step restores all values.
        idx = tx2.reverting(from: idx)
        XCTAssertEqual(idx.children(of: idx.rootID).map { JQValue(node: $0.id, in: idx) },
                       [.int(1), .int(2), .int(3)])
    }

    func testBatchSetValueIgnoresNonScalars() {
        let idx = index(from: obj([("a", .int(1))]))
        // Root object is not a scalar — nothing to set.
        XCTAssertNil(EditTransaction.batchSetValue(ofScalars: [idx.rootID], to: .integer(0),
                                                   description: "x", in: idx))
    }

    // MARK: batchRemove

    func testBatchRemoveDeletesMultipleSiblings() {
        var idx = index(from: .array([.string("a"), .string("b"), .string("c"), .string("d")]))
        let children = idx.children(of: idx.rootID)
        let toRemove = [children[1].id, children[3].id]   // "b" and "d"

        let tx = EditTransaction.batchRemove(toRemove, in: idx)
        guard let tx else { return XCTFail("expected a transaction") }

        idx = tx.applying(to: idx)
        XCTAssertEqual(idx.children(of: idx.rootID).map { JQValue(node: $0.id, in: idx) },
                       [.string("a"), .string("c")])

        idx = tx.reverting(from: idx)
        XCTAssertEqual(idx.children(of: idx.rootID).map { JQValue(node: $0.id, in: idx) },
                       [.string("a"), .string("b"), .string("c"), .string("d")])
    }

    // MARK: batchUpdate (general primitive used by find-&-replace)

    func testBatchUpdateRenamesKeyAndChangesValueInOneStep() {
        var idx = index(from: obj([("name", .string("alice")), ("city", .string("paris"))]))
        // keyValue node for "name" and the scalar value node for "city".
        let kvName = idx.children(of: idx.rootID).first { $0.key == "name" }!
        let kvCity = idx.children(of: idx.rootID).first { $0.key == "city" }!
        let cityValueID = kvCity.childIDs.first!

        var renamed = kvName
        renamed.key = "fullname"
        var newCity = idx.node(for: cityValueID)!
        newCity.value = .scalar(.string("PARIS"))

        let tx = EditTransaction.batchUpdate([kvName.id: renamed, cityValueID: newCity],
                                             description: "Replace All", in: idx)
        guard let tx else { return XCTFail("expected a transaction") }

        idx = tx.applying(to: idx)
        XCTAssertEqual(idx.node(for: kvName.id)?.key, "fullname")
        XCTAssertEqual(JQValue(node: cityValueID, in: idx), .string("PARIS"))

        idx = tx.reverting(from: idx)
        XCTAssertEqual(idx.node(for: kvName.id)?.key, "name")
        XCTAssertEqual(JQValue(node: cityValueID, in: idx), .string("paris"))
    }
}
