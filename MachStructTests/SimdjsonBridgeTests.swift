import XCTest
import CSimdjsonBridge

final class SimdjsonBridgeTests: XCTestCase {

    // MARK: - Helpers

    private func buildIndex(json: String,
                            maxEntries: Int = 10_000) -> [MSIndexEntry] {
        let count = buildIndexRaw(json: json, maxEntries: maxEntries)
        guard count > 0 else { return [] }
        var entries = [MSIndexEntry](repeating: MSIndexEntry(), count: maxEntries)
        _ = json.withCString { ptr in
            ms_build_structural_index(ptr, UInt64(json.utf8.count),
                                      &entries, UInt64(maxEntries))
        }
        return Array(entries.prefix(Int(count)))
    }

    private func buildIndexRaw(json: String, maxEntries: Int = 10_000) -> Int64 {
        var entries = [MSIndexEntry](repeating: MSIndexEntry(), count: maxEntries)
        return json.withCString { ptr in
            ms_build_structural_index(ptr, UInt64(json.utf8.count),
                                      &entries, UInt64(maxEntries))
        }
    }

    // MARK: - Structural correctness

    func testEmptyObject() {
        let entries = buildIndex(json: "{}")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].node_type, UInt8(MS_NODE_TYPE_OBJECT))
        XCTAssertEqual(entries[0].child_count, 0)
        XCTAssertEqual(entries[0].parent_index, -1)
        XCTAssertEqual(entries[0].depth, 0)
    }

    func testEmptyArray() {
        let entries = buildIndex(json: "[]")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].node_type, UInt8(MS_NODE_TYPE_ARRAY))
        XCTAssertEqual(entries[0].child_count, 0)
        XCTAssertEqual(entries[0].parent_index, -1)
        XCTAssertEqual(entries[0].depth, 0)
    }

    func testFlatObject() {
        // {"name":"Alice","age":30}
        // → root(object) + key"name"(string) + "Alice"(string) + key"age"(string) + 30(number)
        let entries = buildIndex(json: #"{"name":"Alice","age":30}"#)
        XCTAssertEqual(entries.count, 5)

        // Root
        XCTAssertEqual(entries[0].node_type,   UInt8(MS_NODE_TYPE_OBJECT))
        XCTAssertEqual(entries[0].parent_index, -1)
        XCTAssertEqual(entries[0].depth,         0)
        XCTAssertEqual(entries[0].child_count,   2)

        // First key
        XCTAssertEqual(entries[1].node_type,    UInt8(MS_NODE_TYPE_STRING))
        XCTAssertEqual(entries[1].parent_index,  0)
        XCTAssertEqual(entries[1].depth,          1)
        XCTAssertEqual(entries[1].child_count,    1)

        // First value
        XCTAssertEqual(entries[2].node_type,    UInt8(MS_NODE_TYPE_STRING))
        XCTAssertEqual(entries[2].parent_index,  1)
        XCTAssertEqual(entries[2].depth,          2)
    }

    func testFlatArray() {
        let entries = buildIndex(json: "[1,2,3]")
        // array + 3 numbers
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0].node_type,   UInt8(MS_NODE_TYPE_ARRAY))
        XCTAssertEqual(entries[0].child_count,  3)
        XCTAssertEqual(entries[1].node_type,   UInt8(MS_NODE_TYPE_NUMBER))
        XCTAssertEqual(entries[1].parent_index, 0)
        XCTAssertEqual(entries[1].depth,         1)
    }

    func testAllScalarTypes() {
        // Covers string, number, bool, null
        let json = #"{"s":"hello","n":42,"f":3.14,"b":true,"nil":null}"#
        let entries = buildIndex(json: json)
        XCTAssertFalse(entries.isEmpty)

        let types = Set(entries.map { $0.node_type })
        XCTAssert(types.contains(UInt8(MS_NODE_TYPE_STRING)))
        XCTAssert(types.contains(UInt8(MS_NODE_TYPE_NUMBER)))
        XCTAssert(types.contains(UInt8(MS_NODE_TYPE_BOOL)))
        XCTAssert(types.contains(UInt8(MS_NODE_TYPE_NULL)))
    }

    func testNestedDepths() {
        let json = #"{"outer":{"inner":"value"}}"#
        let entries = buildIndex(json: json)
        XCTAssertFalse(entries.isEmpty)
        XCTAssertEqual(entries[0].depth, 0)
        // "inner" value should be at depth >= 3
        let maxDepth = entries.map { $0.depth }.max() ?? 0
        XCTAssertGreaterThanOrEqual(maxDepth, 3)
    }

    func testParentChainIsConsistent() {
        let json = #"{"a":{"b":[1,2]}}"#
        let entries = buildIndex(json: json)
        // Every non-root entry should have a parent_index in [0, count-1]
        for (i, entry) in entries.enumerated() {
            if i == 0 {
                XCTAssertEqual(entry.parent_index, -1, "root must have parent -1")
            } else {
                XCTAssertGreaterThanOrEqual(entry.parent_index, 0)
                XCTAssertLessThan(entry.parent_index, Int64(entries.count))
            }
        }
    }

    func testDepthMonotonicallyRelatedToParent() {
        let json = #"{"x":{"y":{"z":42}}}"#
        let entries = buildIndex(json: json)
        for entry in entries where entry.parent_index >= 0 {
            let parent = entries[Int(entry.parent_index)]
            XCTAssertEqual(entry.depth, parent.depth + 1,
                           "child depth must be parent.depth + 1")
        }
    }

    // MARK: - Error handling

    func testInvalidJSONReturnsError() {
        let result = buildIndexRaw(json: "{ invalid json }")
        XCTAssertLessThan(result, 0)
    }

    func testTruncatedJSONReturnsError() {
        let result = buildIndexRaw(json: #"{"key":"val"#)   // missing closing }
        XCTAssertLessThan(result, 0)
    }

    // MARK: - Edge cases

    func testScalarRootString() {
        let entries = buildIndex(json: #""hello""#)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].node_type, UInt8(MS_NODE_TYPE_STRING))
    }

    func testScalarRootNumber() {
        let entries = buildIndex(json: "42")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].node_type, UInt8(MS_NODE_TYPE_NUMBER))
    }

    func testDeeplyNestedArray() {
        // [[[[1]]]]
        let json = "[[[[1]]]]"
        let entries = buildIndex(json: json)
        XCTAssertFalse(entries.isEmpty)
        // The innermost number should be at depth 4
        let deepest = entries.max(by: { $0.depth < $1.depth })
        XCTAssertEqual(deepest?.node_type, UInt8(MS_NODE_TYPE_NUMBER))
        XCTAssertEqual(deepest?.depth, 4)
    }
}
