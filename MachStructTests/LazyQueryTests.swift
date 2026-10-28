import XCTest
@testable import MachStructCore

/// jq queries on a large file read it through a `DocumentOverlay`, and the
/// engine projects only what a query needs: one node for a navigation, one
/// item at a time for `P | .[] | rest` (ADR-002 stage 3). The outputs, errors
/// and matched nodes must be what evaluating the whole document gives.
final class LazyQueryTests: XCTestCase {

    private func source(_ text: String, csv: Bool = false) throws -> any DocumentSource {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lazy-query-\(UUID().uuidString).\(csv ? "csv" : "json")")
        try Data(text.utf8).write(to: url)
        let file = try MappedFile(url: url)
        return csv ? CSVSource(file: file) : try JSONSource(file: file)
    }

    private func rootOnly(_ source: any DocumentSource) throws -> NodeIndex {
        NodeIndex(root: try XCTUnwrap(source.node(for: source.rootID, parent: nil)))
    }

    private enum Outcome: Equatable {
        case values([JQValue], Set<NodeID>?)
        case parseError
        case runtimeError(String)
    }

    /// What the engine gave before: the whole document projected and
    /// evaluated, and path-only queries resolved from the root.
    private func reference(_ query: String, _ full: NodeIndex) -> Outcome {
        guard let expr = try? JQParser.parse(query) else { return .parseError }
        do {
            let values = try JQEvaluator.evaluate(expr, against: JQValue(node: full.rootID, in: full))
            var ids: [NodeID]?
            if JQPath.isPathOnly(expr),
               let found = try? JQPath.resolve(expr, from: [full.rootID], in: full),
               found.count == values.count {
                ids = found
            }
            return .values(values, ids.map(Set.init))
        } catch let e as JQRuntimeError {
            return .runtimeError(e.message)
        } catch {
            return .runtimeError("\(error)")
        }
    }

    private func run<Lookup: NodeLookup>(_ query: String, _ document: Lookup) async -> Outcome {
        do {
            let result = try await QueryEngine().run(query, on: document)
            // Each output's node is that output: the order matters, which
            // the comparison with the old engine (as sets) doesn't check.
            if let ids = result.sourceNodeIDs {
                XCTAssertEqual(ids.map { JQValue(node: $0, in: document) }, result.values, query)
            }
            return .values(result.values, result.sourceNodeIDs.map(Set.init))
        } catch QueryEngine.QueryError.parse {
            return .parseError
        } catch QueryEngine.QueryError.runtime(let e) {
            return .runtimeError(e.message)
        } catch {
            return .runtimeError("\(error)")
        }
    }

    private let documents = [
        ("rows", #"""
            [{"name":"alice","age":30,"tags":["a","b"]},
             {"name":"bob","age":41,"tags":[]},
             {"name":"carol","age":null,"tags":["c"],"name":"dup"},
             7, "str", null]
            """#),
        ("object rows", #"[{"name":"alice","age":30},{"name":"bob","age":41}]"#),
        ("wrapped", #"{"users":[{"name":"alice","tags":["x"]},{"name":"bob","tags":[]}],"meta":{"count":2},"empty":[]}"#),
        ("empty", "[]"),
        ("scalar", "42"),
        ("deep", #"{"a":{"b":{"c":[1,2,{"d":"e"}]}},"a":"shadowed"}"#),
    ]

    private let queries = [
        ".", ".[]", ".[]?", ".[0]", ".[-1]", ".[10]", ".[1.5]", ".[\"name\"]",
        ".[].name", ".[] | .name", ".[]? | .name?", ".[] | .name?", ".[0].name",
        ".[] | select(.age > 30)", ".[] | select(.age > 30) | .name",
        ".[] | (.name, .age)", ".[][]", ".[][]?", ".[] | .tags[]", ".[] | .tags[0]",
        ".[] | .tags[0]?", ".[][1/0]", ".[] | .missing", ".[] | .missing[]",
        ".[] | .missing[]?", "[.[] | .age]", ".[] | {n: .name}", ".[] | .age + 1",
        ".[] | values", ".[] | keys", "map(.name)", "length", ".[] | length",
        ".users", ".users[]", ".users[].name", ".users[] | select(.name == \"bob\")",
        ".users[].tags[]", ".users[0].tags", ".meta.count", ".empty[]", ".empty[] | .x",
        ".a.b.c", ".a.b.c[]", ".a.b.c[2].d", ".a | .b", ".[", "nonsense(",
        ".[][.name]", ".[][\"name\"]", ".a", ".[2].name", ".[2][\"name\"]",
        ".[0,1]", ".[1,0] | .name", ".[] | .tags[-1]", ".[] | .tags[0,1]", "(.[0], .[1]) | .name",
        ".[] | values | .name?", ".[] | select(.age) | .age",
        ".users[] | select(.name == \"bob\") | .tags[]", ".users[1:]", ".[]?.name?", ".[] | .[]?",
        ".users | .[] | .name, .tags", ".meta | .count, .missing", ".a.b | .c | .[-2]",
    ]

    private func assertMatchesReference<Lookup: NodeLookup>(_ document: Lookup, full: NodeIndex,
                                                            _ label: String,
                                                            line: UInt = #line) async {
        for query in queries {
            let expected = reference(query, full)
            let actual = await run(query, document)
            XCTAssertEqual(actual, expected, "\(label): \(query)", line: line)
        }
    }

    // MARK: - Equivalence

    func testQueriesMatchEvaluatingTheWholeDocument() async throws {
        for (label, text) in documents {
            let src = try source(text)
            let opened = try rootOnly(src)
            let full = src.completeNodeIndex(overlaying: opened)
            await assertMatchesReference(full, full: full, "\(label), whole index")
            await assertMatchesReference(DocumentOverlay(index: opened, source: src), full: full,
                                         "\(label), nothing loaded")
        }
    }

    func testQueriesSeeEdits() async throws {
        let src = try source(documents[2].1)
        var index = try rootOnly(src)
        // Load the path to the first user's name and rename her.
        let full = src.completeNodeIndex(overlaying: index)
        let alice = try XCTUnwrap(full.nodesMatching {
            if case .scalar(.string("alice")) = $0.value { return true } else { return false }
        }.first)
        index = src.loading([alice.id], subtrees: false, into: index)
        index.updateNode(alice.id) { $0.value = .scalar(.string("ALICE")) }

        let edited = src.completeNodeIndex(overlaying: index)
        await assertMatchesReference(DocumentOverlay(index: index, source: src), full: edited,
                                     "edited")
        let result = try await QueryEngine().run(".users[].name", on: DocumentOverlay(index: index, source: src))
        XCTAssertEqual(result.values, [.string("ALICE"), .string("bob")])
    }

    func testCSVQueriesMatchEvaluatingTheWholeDocument() async throws {
        let src = try source("name,age\nalice,30\nbob,41\n", csv: true)
        let opened = try rootOnly(src)
        await assertMatchesReference(DocumentOverlay(index: opened, source: src),
                                     full: src.completeNodeIndex(overlaying: opened), "csv")
    }

    // MARK: - Shortcuts

    /// The shortcuts must be taken, not just fall back to the whole document.
    func testNavigationAndIterationAreRecognised() throws {
        let src = try source(documents[0].1)
        let document = DocumentOverlay(index: try rootOnly(src), source: src)
        let root = try XCTUnwrap(document.node(for: document.rootID))
        func expr(_ q: String) throws -> JQExpr { try JQParser.parse(q) }

        XCTAssertEqual(JQPath.navigate(try expr(".[-1]"), in: document), root.childIDs.last)
        let carol = try XCTUnwrap(document.node(for: root.childIDs[2]))
        let firstName = try XCTUnwrap(document.node(for: carol.childIDs[0])?.childIDs.first)
        XCTAssertEqual(JQPath.navigate(try expr(".[2].name"), in: document), firstName)
        XCTAssertNil(JQPath.navigate(try expr(".[2].missing"), in: document))

        let split = try XCTUnwrap(JQPath.splitAtIteration(try expr(".[] | .name"), in: document))
        XCTAssertEqual(split.items, root.childIDs)
        XCTAssertEqual(split.rest, .pipe(.identity, .field(base: .identity, name: "name", optional: false)))
        XCTAssertNotNil(JQPath.splitAtIteration(try expr(".[2].tags[] | length"), in: document))
        XCTAssertNil(JQPath.splitAtIteration(try expr("map(.name)"), in: document))
    }

    /// `select` outputs its input once for each true result, and each output
    /// is that node. The old resolver kept it once, so the counts differed
    /// and no nodes were found.
    func testRepeatedSelectOutputsAreEachTheirNode() async throws {
        let src = try source(documents[1].1)
        let document = DocumentOverlay(index: try rootOnly(src), source: src)
        let result = try await QueryEngine().run(".[] | select(true, true) | .name", on: document)
        XCTAssertEqual(result.values, [.string("alice"), .string("alice"), .string("bob"), .string("bob")])
        let ids = try XCTUnwrap(result.sourceNodeIDs)
        XCTAssertEqual(ids.count, 4)
        XCTAssertEqual(ids[0], ids[1])
        XCTAssertEqual(ids[2], ids[3])
        XCTAssertEqual(ids.compactMap { document.node(for: $0) }.map { JQValue(node: $0.id, in: document) },
                       result.values)
    }

    // MARK: - Loading for an edit

    func testLoadingBringsAncestorsAndSubtreesAsParsed() throws {
        let src = try source(documents[2].1)
        let opened = try rootOnly(src)
        let full = src.completeNodeIndex(overlaying: opened)
        let users = try XCTUnwrap(full.nodesMatching { $0.key == "users" }.first)
        let array = try XCTUnwrap(users.childIDs.first)
        let first = try XCTUnwrap(full.node(for: array)?.childIDs.first)

        let pathOnly = src.loading([first], subtrees: false, into: opened)
        XCTAssertEqual(Set(pathOnly.allNodeIDs), [opened.rootID, users.id, array, first])
        XCTAssertEqual(pathOnly.node(for: first)?.parentID, array)
        XCTAssertEqual(pathOnly.node(for: first)?.depth, full.node(for: first)?.depth)

        let withSubtree = src.loading([first], subtrees: true, into: opened)
        let subtree = full.nodesMatching { _ in true }.filter { node in
            var id: NodeID? = node.id
            while let current = id, current != first { id = full.node(for: current)?.parentID }
            return id == first
        }.map(\.id)
        XCTAssertTrue(Set(subtree).isSubset(of: Set(withSubtree.allNodeIDs)))
        XCTAssertEqual(withSubtree.count, 3 + subtree.count)
    }

    /// An ancestor loaded when the nodes were gathered may be evicted before
    /// they are loaded; it must come back, or saving drops the edit.
    func testNodesToLoadIncludeThoseTheIndexHolds() throws {
        let src = try source(documents[2].1)
        let opened = try rootOnly(src)
        let full = src.completeNodeIndex(overlaying: opened)
        let users = try XCTUnwrap(full.nodesMatching { $0.key == "users" }.first)
        let array = try XCTUnwrap(users.childIDs.first)
        let first = try XCTUnwrap(full.node(for: array)?.childIDs.first)
        let loaded = src.loading([array], subtrees: false, into: opened)

        let nodes = src.nodesToLoad(for: [first], subtrees: false, in: loaded)
        var evicted = loaded
        evicted.evictNodes([array])
        evicted.load(nodes)

        XCTAssertNotNil(evicted.node(for: array))
        XCTAssertEqual(Set(evicted.allNodeIDs), [opened.rootID, users.id, array, first])
    }
}

// MARK: - Reference

/// How the engine found a path-only query's nodes before it located them
/// while evaluating: by walking the query again from its input.
extension JQPath {

    /// Resolve the node IDs selected by a path-only `expr`, starting from
    /// `nodeIDs`, in document order.
    static func resolve<Lookup: NodeLookup>(_ expr: JQExpr, from nodeIDs: [NodeID],
                                            in index: Lookup) throws -> [NodeID] {
        switch expr {
        case .identity:
            return nodeIDs

        case .field(let base, let name, let optional):
            let bases = try resolve(base, from: nodeIDs, in: index)
            var out: [NodeID] = []
            for baseID in bases {
                guard let node = index.node(for: baseID) else { continue }
                if node.type == .object {
                    if let kvID = node.childIDs.first(where: { index.node(for: $0)?.key == name }),
                       let valueID = index.node(for: kvID)?.childIDs.first {
                        out.append(valueID)
                    }
                    // Missing key → null with no node; skip (can't map back).
                } else if !optional {
                    throw JQRuntimeError("Cannot index \(jqTypeName(node)) with \"\(name)\"")
                }
            }
            return out

        case .index(let base, let idxExpr, let optional):
            let bases = try resolve(base, from: nodeIDs, in: index)
            // Constant index resolved against null input.
            let idxValues = try JQEvaluator.evaluate(idxExpr, against: .null)
            var out: [NodeID] = []
            for baseID in bases {
                guard let node = index.node(for: baseID) else { continue }
                for idxValue in idxValues {
                    if node.type == .array, case .int(let i) = idxValue {
                        let n = node.childIDs.count
                        let pos = i < 0 ? Int(i) + n : Int(i)
                        if pos >= 0 && pos < n { out.append(node.childIDs[pos]) }
                    } else if node.type == .object, case .string(let key) = idxValue {
                        if let kvID = node.childIDs.first(where: { index.node(for: $0)?.key == key }),
                           let valueID = index.node(for: kvID)?.childIDs.first {
                            out.append(valueID)
                        }
                    } else if !optional {
                        throw JQRuntimeError("Cannot index \(jqTypeName(node))")
                    }
                }
            }
            return out

        case .iterate(let base, let optional):
            let bases = try resolve(base, from: nodeIDs, in: index)
            var out: [NodeID] = []
            for baseID in bases {
                guard let node = index.node(for: baseID) else { continue }
                switch node.type {
                case .array:
                    out.append(contentsOf: node.childIDs)
                case .object:
                    for kvID in node.childIDs {
                        if let valueID = index.node(for: kvID)?.childIDs.first {
                            out.append(valueID)
                        }
                    }
                default:
                    if !optional { throw JQRuntimeError("Cannot iterate over \(jqTypeName(node))") }
                }
            }
            return out

        case .pipe(let a, let b):
            return try resolve(b, from: resolve(a, from: nodeIDs, in: index), in: index)

        case .comma(let a, let b):
            return try resolve(a, from: nodeIDs, in: index) + resolve(b, from: nodeIDs, in: index)

        case .call("select", let args) where args.count == 1:
            var out: [NodeID] = []
            for nodeID in nodeIDs {
                let projection = JQValue(node: nodeID, in: index)
                let results = try JQEvaluator.evaluate(args[0], against: projection)
                if results.contains(where: { truthy($0) }) { out.append(nodeID) }
            }
            return out

        case .call("values", let args) where args.isEmpty:
            return nodeIDs.filter { JQValue(node: $0, in: index) != .null }

        default:
            throw JQRuntimeError("Query is not a path expression")
        }
    }

    private static func truthy(_ v: JQValue) -> Bool {
        switch v {
        case .null, .bool(false): return false
        default:                  return true
        }
    }

    private static func jqTypeName(_ node: DocumentNode) -> String {
        switch node.type {
        case .object:   return "object"
        case .array:    return "array"
        case .keyValue: return "object"
        case .scalar:
            if case .scalar(let sv) = node.value { return JQValue(scalar: sv).typeName }
            return "null"
        }
    }
}
