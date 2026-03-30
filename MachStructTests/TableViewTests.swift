import XCTest
@testable import MachStructCore

// MARK: - TableViewTests

/// Tests for `NodeIndex.isTabular()` and `NodeIndex.tabularColumns`.
///
/// The `TableView` SwiftUI component itself is covered by the Xcode Preview
/// defined in `TableView.swift`.
final class TableViewTests: XCTestCase {

    // MARK: - Helpers

    /// Build a NodeIndex representing a tabular document.
    ///
    ///     root (array)
    ///       row₀ (object)  → keyValue "a" → scalar
    ///                       keyValue "b" → scalar
    ///       row₁ (object)  → same keys
    private func makeTabularIndex(
        columns: [String],
        rows: [[ScalarValue]],
        rootType: NodeType = .array,
        rowType: NodeType = .object
    ) -> NodeIndex {
        let root = DocumentNode(type: rootType, value: .container(childCount: rows.count))
        var idx  = NodeIndex(root: root)

        for (ri, values) in rows.enumerated() {
            let row = DocumentNode(
                id: .generate(), type: rowType, depth: 1,
                parentID: root.id,
                value: .container(childCount: columns.count))
            idx.insertChild(row, in: root.id, at: ri)

            for (ci, col) in columns.enumerated() {
                let kv = DocumentNode(
                    id: .generate(), type: .keyValue, depth: 2,
                    parentID: row.id, key: col, value: .unparsed)
                let scalar = DocumentNode(
                    id: .generate(), type: .scalar, depth: 3,
                    parentID: kv.id,
                    value: ci < values.count ? .scalar(values[ci]) : .scalar(.null))
                idx.insertChild(kv,     in: row.id, at: ci)
                idx.insertChild(scalar, in: kv.id,  at: 0)
            }
        }
        return idx
    }

    // MARK: - isTabular

    func testUniformObjectArrayIsTabular() {
        let idx = makeTabularIndex(
            columns: ["name", "age"],
            rows: [[.string("Alice"), .integer(30)],
                   [.string("Bob"),   .integer(25)]])
        XCTAssertTrue(idx.isTabular())
    }

    func testSingleRowIsTabular() {
        let idx = makeTabularIndex(
            columns: ["x", "y"],
            rows:    [[.integer(1), .integer(2)]])
        XCTAssertTrue(idx.isTabular())
    }

    func testSingleColumnIsTabular() {
        let idx = makeTabularIndex(
            columns: ["value"],
            rows:    [[.string("hello")], [.string("world")]])
        XCTAssertTrue(idx.isTabular())
    }

    func testEmptyRowsNotTabular() {
        // root array with no children
        let root = DocumentNode(type: .array, value: .container(childCount: 0))
        let idx  = NodeIndex(root: root)
        XCTAssertFalse(idx.isTabular())
    }

    func testNonArrayRootNotTabular() {
        let root = DocumentNode(type: .object, value: .container(childCount: 1))
        let idx  = NodeIndex(root: root)
        XCTAssertFalse(idx.isTabular())
    }

    func testScalarRootNotTabular() {
        let root = DocumentNode(type: .scalar, value: .scalar(.integer(42)))
        let idx  = NodeIndex(root: root)
        XCTAssertFalse(idx.isTabular())
    }

    func testArrayOfScalarsNotTabular() {
        // root → array of scalars, not objects
        let root = DocumentNode(type: .array, value: .container(childCount: 2))
        var idx  = NodeIndex(root: root)
        let s0   = DocumentNode(id: .generate(), type: .scalar, depth: 1,
                                parentID: root.id, key: "0", value: .scalar(.integer(1)))
        let s1   = DocumentNode(id: .generate(), type: .scalar, depth: 1,
                                parentID: root.id, key: "1", value: .scalar(.integer(2)))
        idx.insertChild(s0, in: root.id, at: 0)
        idx.insertChild(s1, in: root.id, at: 1)
        XCTAssertFalse(idx.isTabular())
    }

    func testNonUniformKeysNotTabular() {
        let root = DocumentNode(type: .array, value: .container(childCount: 2))
        var idx  = NodeIndex(root: root)

        // Row 0: keys ["a", "b"]
        let r0 = DocumentNode(id: .generate(), type: .object, depth: 1,
                              parentID: root.id, value: .container(childCount: 2))
        let k0 = DocumentNode(id: .generate(), type: .keyValue, depth: 2,
                              parentID: r0.id, key: "a", value: .unparsed)
        let k1 = DocumentNode(id: .generate(), type: .keyValue, depth: 2,
                              parentID: r0.id, key: "b", value: .unparsed)
        idx.insertChild(r0, in: root.id, at: 0)
        idx.insertChild(k0, in: r0.id,   at: 0)
        idx.insertChild(k1, in: r0.id,   at: 1)

        // Row 1: keys ["a", "c"] — different from row 0
        let r1 = DocumentNode(id: .generate(), type: .object, depth: 1,
                              parentID: root.id, value: .container(childCount: 2))
        let k2 = DocumentNode(id: .generate(), type: .keyValue, depth: 2,
                              parentID: r1.id, key: "a", value: .unparsed)
        let k3 = DocumentNode(id: .generate(), type: .keyValue, depth: 2,
                              parentID: r1.id, key: "c", value: .unparsed)
        idx.insertChild(r1, in: root.id, at: 1)
        idx.insertChild(k2, in: r1.id,   at: 0)
        idx.insertChild(k3, in: r1.id,   at: 1)

        XCTAssertFalse(idx.isTabular())
    }

    func testSampleSizeParameterRespected() {
        // 20 uniform rows; sampleSize = 5 should still return true
        let idx = makeTabularIndex(
            columns: ["x"],
            rows: (0..<20).map { [.integer(Int64($0))] })
        XCTAssertTrue(idx.isTabular(sampleSize: 5))
    }

    func testObjectWithNoKeysNotTabular() {
        // Empty objects have no keys → not tabular
        let root = DocumentNode(type: .array, value: .container(childCount: 2))
        var idx  = NodeIndex(root: root)
        let r0   = DocumentNode(id: .generate(), type: .object, depth: 1,
                                parentID: root.id, value: .container(childCount: 0))
        let r1   = DocumentNode(id: .generate(), type: .object, depth: 1,
                                parentID: root.id, value: .container(childCount: 0))
        idx.insertChild(r0, in: root.id, at: 0)
        idx.insertChild(r1, in: root.id, at: 1)
        XCTAssertFalse(idx.isTabular())
    }

    // MARK: - tabularColumns

    func testTabularColumnsReturnedInOrder() {
        let idx = makeTabularIndex(
            columns: ["name", "age", "city"],
            rows:    [[.string("A"), .integer(1), .string("X")]])
        XCTAssertEqual(idx.tabularColumns, ["name", "age", "city"])
    }

    func testTabularColumnsEmptyForNonTabular() {
        let root = DocumentNode(type: .object, value: .container(childCount: 0))
        let idx  = NodeIndex(root: root)
        XCTAssertEqual(idx.tabularColumns, [])
    }

    func testTabularColumnsEmptyForEmptyArray() {
        let root = DocumentNode(type: .array, value: .container(childCount: 0))
        let idx  = NodeIndex(root: root)
        XCTAssertEqual(idx.tabularColumns, [])
    }

    // MARK: - Integration with CSVParser

    func testCSVBuildIndexIsTabular() async throws {
        let csv  = "name,age,city\nAlice,30,NYC\nBob,25,LA\n"
        let data = csv.data(using: .utf8)!
        let url  = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabular-\(UUID().uuidString).csv")
        try data.write(to: url)
        let file = try MappedFile(url: url)

        let structural = try await CSVParser().buildIndex(from: file)
        let nodeIndex  = structural.buildNodeIndex()

        XCTAssertTrue(nodeIndex.isTabular())
        XCTAssertEqual(nodeIndex.tabularColumns, ["name", "age", "city"])
    }

    func testCSVWithNoHeaderIsTabular() async throws {
        // All-numeric rows → no header → rows are arrays, not objects → NOT tabular
        let csv  = "1,2,3\n4,5,6\n"
        let data = csv.data(using: .utf8)!
        let url  = FileManager.default.temporaryDirectory
            .appendingPathComponent("noheader-\(UUID().uuidString).csv")
        try data.write(to: url)
        let file = try MappedFile(url: url)

        let structural = try await CSVParser().buildIndex(from: file)
        let nodeIndex  = structural.buildNodeIndex()

        // No-header CSV → rows are .array, not .object → not tabular
        XCTAssertFalse(nodeIndex.isTabular())
    }

    func testJSONArrayOfObjectsIsTabular() async throws {
        let json = "[{\"name\":\"Alice\",\"age\":30},{\"name\":\"Bob\",\"age\":25}]"
        let data = json.data(using: .utf8)!
        let url  = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabular-\(UUID().uuidString).json")
        try data.write(to: url)
        let file = try MappedFile(url: url)

        let structural = try await JSONParser().buildIndex(from: file)
        let nodeIndex  = structural.buildNodeIndex()

        XCTAssertTrue(nodeIndex.isTabular())
        // JSON objects don't guarantee key order — check set membership only.
        XCTAssertEqual(Set(nodeIndex.tabularColumns), ["name", "age"])
    }

    func testJSONObjectIsNotTabular() async throws {
        let json = "{\"name\":\"Alice\",\"age\":30}"
        let data = json.data(using: .utf8)!
        let url  = FileManager.default.temporaryDirectory
            .appendingPathComponent("notabular-\(UUID().uuidString).json")
        try data.write(to: url)
        let file = try MappedFile(url: url)

        let structural = try await JSONParser().buildIndex(from: file)
        let nodeIndex  = structural.buildNodeIndex()

        XCTAssertFalse(nodeIndex.isTabular())
    }
}
