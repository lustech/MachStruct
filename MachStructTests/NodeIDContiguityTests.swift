import XCTest
@testable import MachStructCore

/// Regression tests for issue #14.
///
/// `StructuralIndex.entry(for:)` resolves a NodeID by arithmetic on
/// `entryIDBase`, which requires each document's NodeIDs to be *contiguous*.
/// `NodeID.generate()` draws from one global counter, so two documents parsed
/// concurrently used to interleave their IDs — after which `entry(for:)`
/// silently returned a different node's entry, and `path(to:)` could walk a
/// corrupted parent chain forever on the main actor.
final class NodeIDContiguityTests: XCTestCase {

    private func makeFile(json: String, tag: String) throws -> MappedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("contig-\(tag)-\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: url)
        return try MappedFile(url: url)
    }

    private func assertContiguous(_ si: StructuralIndex,
                                  _ label: String,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        for (i, entry) in si.entries.enumerated() {
            XCTAssertEqual(entry.id.rawValue, si.entryIDBase &+ UInt64(i),
                           "\(label): entry \(i) breaks contiguity",
                           file: file, line: line)
        }
    }

    /// Every ID must resolve back to its own entry, not a neighbour's.
    private func assertLookupsRoundTrip(_ si: StructuralIndex,
                                        _ label: String,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
        for entry in si.entries {
            XCTAssertEqual(si.entry(for: entry.id)?.id, entry.id,
                           "\(label): entry(for:) resolved the wrong entry",
                           file: file, line: line)
        }
    }

    // MARK: - Concurrent parses

    /// Two documents opening at once — each gets its own detached parse task.
    func testConcurrentParsesProduceContiguousIDs() async throws {
        let jsonA = "{" + (0..<400).map { #""a\#($0)": "v\#($0)""# }
            .joined(separator: ",") + "}"
        let jsonB = "{" + (0..<400).map { #""b\#($0)": \#($0)"# }
            .joined(separator: ",") + "}"
        let fileA = try makeFile(json: jsonA, tag: "A")
        let fileB = try makeFile(json: jsonB, tag: "B")

        async let a = JSONParser().buildIndex(from: fileA)
        async let b = JSONParser().buildIndex(from: fileB)
        let (siA, siB) = try await (a, b)

        assertContiguous(siA, "A")
        assertContiguous(siB, "B")
        assertLookupsRoundTrip(siA, "A")
        assertLookupsRoundTrip(siB, "B")
    }

    /// Many parses at once, to shake out interleavings a two-way race misses.
    func testManyConcurrentParsesStayIsolated() async throws {
        let indices: [StructuralIndex] = try await withThrowingTaskGroup(
            of: StructuralIndex.self
        ) { group in
            for n in 0..<8 {
                group.addTask {
                    let json = "{" + (0..<120).map { #""k\#(n)_\#($0)": \#($0)"# }
                        .joined(separator: ",") + "}"
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("multi-\(n)-\(UUID().uuidString).json")
                    try json.data(using: .utf8)!.write(to: url)
                    return try await JSONParser().buildIndex(from: MappedFile(url: url))
                }
            }
            var out = [StructuralIndex]()
            for try await si in group { out.append(si) }
            return out
        }

        XCTAssertEqual(indices.count, 8)
        for (n, si) in indices.enumerated() {
            assertContiguous(si, "doc\(n)")
            assertLookupsRoundTrip(si, "doc\(n)")
        }
    }

    /// Documents parsed concurrently must not resolve each other's IDs.
    func testForeignIDsDoNotResolve() async throws {
        let fileA = try makeFile(json: #"{"a":1,"b":2}"#, tag: "fa")
        let fileB = try makeFile(json: #"{"c":3,"d":4}"#, tag: "fb")
        async let a = JSONParser().buildIndex(from: fileA)
        async let b = JSONParser().buildIndex(from: fileB)
        let (siA, siB) = try await (a, b)

        for entry in siB.entries {
            // A foreign ID may land inside A's arithmetic range; it must still
            // be rejected rather than silently resolving to some other node.
            if let resolved = siA.entry(for: entry.id) {
                XCTAssertEqual(resolved.id, entry.id,
                               "foreign ID resolved to an unrelated entry")
            }
        }
    }

    // MARK: - path(to:) termination

    /// A corrupted parent chain must not loop forever. Builds an index whose
    /// parent links form a cycle and asserts the walk still terminates.
    func testPathToTerminatesOnCyclicParentChain() throws {
        let id0 = NodeID(rawValue: 9_000), id1 = NodeID(rawValue: 9_001)
        let cyclic = [
            IndexEntry(id: id0, nodeType: .object, depth: 0, parentID: id1),
            IndexEntry(id: id1, nodeType: .object, depth: 1, parentID: id0),
        ]
        let si = StructuralIndex(entries: cyclic)

        // Must return rather than hang or grow without bound.
        let path = si.path(to: si.entries[1].id)
        XCTAssertLessThanOrEqual(path.count, cyclic.count + 1,
                                 "path(to:) did not break the cycle")
    }

    func testNodeIndexPathTerminatesOnCyclicParentChain() throws {
        var a = DocumentNode(type: .object, value: .container(childCount: 1))
        var b = DocumentNode(type: .object, value: .container(childCount: 1))
        a.parentID = b.id
        b.parentID = a.id
        var index = NodeIndex(root: a)
        index.insert(b)

        let path = index.path(to: b.id)
        XCTAssertLessThanOrEqual(path.count, 3,
                                 "NodeIndex.path(to:) did not break the cycle")
    }

    // MARK: - Ordinary behaviour must be unchanged

    func testSingleParseKeepsDocumentOrderAndLookups() async throws {
        let file = try makeFile(json: #"{"a":{"b":[1,2,3]},"c":"x"}"#, tag: "solo")
        let si = try await JSONParser().buildIndex(from: file)

        assertContiguous(si, "solo")
        assertLookupsRoundTrip(si, "solo")

        // Root is first, and the parent chain still reaches it.
        let root = try XCTUnwrap(si.entries.first)
        XCTAssertNil(root.parentID)
        for entry in si.entries {
            let path = si.path(to: entry.id)
            XCTAssertEqual(path.first, root.id, "path should start at the root")
            XCTAssertEqual(path.last, entry.id, "path should end at the node")
        }
    }

    // MARK: - Deterministic repair

    /// The concurrency tests above depend on scheduling, so pin the repair
    /// itself: hand `init` a deliberately interleaved run of IDs and assert it
    /// is renumbered contiguously with parent links intact.
    func testNonContiguousEntriesAreRenumberedPreservingStructure() throws {
        // root(10) -> kv(13) -> scalar(17), plus kv(21) -> scalar(29).
        let root = NodeID(rawValue: 10), kv1 = NodeID(rawValue: 13)
        let sc1 = NodeID(rawValue: 17), kv2 = NodeID(rawValue: 21)
        let sc2 = NodeID(rawValue: 29)
        let interleaved = [
            IndexEntry(id: root, nodeType: .object, depth: 0, parentID: nil, childCount: 2),
            IndexEntry(id: kv1, nodeType: .keyValue, depth: 1, parentID: root,
                       childCount: 1, key: "first"),
            IndexEntry(id: sc1, nodeType: .scalar, depth: 2, parentID: kv1,
                       parsedValue: .integer(1)),
            IndexEntry(id: kv2, nodeType: .keyValue, depth: 1, parentID: root,
                       childCount: 1, key: "second"),
            IndexEntry(id: sc2, nodeType: .scalar, depth: 2, parentID: kv2,
                       parsedValue: .boolean(true)),
        ]

        let si = StructuralIndex(entries: interleaved)

        // Contiguous after repair.
        for (i, entry) in si.entries.enumerated() {
            XCTAssertEqual(entry.id.rawValue, si.entryIDBase &+ UInt64(i))
            XCTAssertEqual(si.entry(for: entry.id)?.id, entry.id)
        }

        // Tree shape survived: same order, same keys, same values, same links.
        XCTAssertEqual(si.entries.map(\.nodeType),
                       [.object, .keyValue, .scalar, .keyValue, .scalar])
        XCTAssertEqual(si.entries.compactMap(\.key), ["first", "second"])
        XCTAssertEqual(si.entries[2].parsedValue, .integer(1))
        XCTAssertEqual(si.entries[4].parsedValue, .boolean(true))

        XCTAssertNil(si.entries[0].parentID)
        XCTAssertEqual(si.entries[1].parentID, si.entries[0].id)
        XCTAssertEqual(si.entries[2].parentID, si.entries[1].id)
        XCTAssertEqual(si.entries[3].parentID, si.entries[0].id)
        XCTAssertEqual(si.entries[4].parentID, si.entries[3].id)

        // Stale (pre-renumber) IDs must not resolve to some other node.
        for stale in [root, kv1, sc1, kv2, sc2] {
            if let got = si.entry(for: stale) {
                XCTAssertEqual(got.id, stale, "stale ID resolved to another node")
            }
        }

        // Child wiring derived from the repaired links.
        XCTAssertEqual(si.childIndices[si.entries[0].id], [1, 3])
        XCTAssertEqual(si.path(to: si.entries[4].id),
                       [si.entries[0].id, si.entries[3].id, si.entries[4].id])
    }

    /// Already-contiguous input must pass through untouched (the hot path).
    func testContiguousEntriesAreNotRenumbered() throws {
        let base = NodeID.reserveBlock(count: 3)
        let ids = (0..<3).map { NodeID(rawValue: base &+ UInt64($0)) }
        let entries = [
            IndexEntry(id: ids[0], nodeType: .object, depth: 0, parentID: nil, childCount: 1),
            IndexEntry(id: ids[1], nodeType: .keyValue, depth: 1, parentID: ids[0],
                       childCount: 1, key: "k"),
            IndexEntry(id: ids[2], nodeType: .scalar, depth: 2, parentID: ids[1],
                       parsedValue: .string("v")),
        ]
        let si = StructuralIndex(entries: entries)
        XCTAssertEqual(si.entries.map(\.id), ids, "contiguous IDs should be preserved")
        XCTAssertEqual(si.entryIDBase, base)
    }

}
