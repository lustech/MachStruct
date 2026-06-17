import XCTest
@testable import MachStructCore

// MARK: - QueryEngine

final class QueryEngineTests: XCTestCase {

    /// Build a NodeIndex from a JQValue (same node shape as a real document).
    private func index(from value: JQValue) -> NodeIndex {
        let built = value.toDocumentNodes(parentID: nil, depth: 0, key: nil)
        return NodeIndex(rootID: built.root, allNodes: built.nodes)
    }

    private func obj(_ pairs: [(String, JQValue)]) -> JQValue { .object(pairs.map { ($0.0, $0.1) }) }

    private var sampleDoc: JQValue {
        obj([("users", .array([
            obj([("name", .string("alice")), ("age", .int(40))]),
            obj([("name", .string("bob")), ("age", .int(25))]),
            obj([("name", .string("carol")), ("age", .int(35))]),
        ]))])
    }

    func testRunReturnsValues() async throws {
        let engine = QueryEngine()
        let result = try await engine.run(".users[] | select(.age > 30) | .name",
                                          on: index(from: sampleDoc))
        XCTAssertEqual(result.values, [.string("alice"), .string("carol")])
    }

    func testParseErrorSurfaces() async {
        let engine = QueryEngine()
        do {
            _ = try await engine.run(".[", on: index(from: sampleDoc))
            XCTFail("expected parse error")
        } catch let QueryEngine.QueryError.parse(err) {
            XCTAssertGreaterThanOrEqual(err.column, 0)
        } catch {
            XCTFail("expected parse error, got \(error)")
        }
    }

    func testRuntimeErrorSurfaces() async {
        let engine = QueryEngine()
        do {
            _ = try await engine.run(".name", on: index(from: .int(5)))
            XCTFail("expected runtime error")
        } catch QueryEngine.QueryError.runtime {
            // expected
        } catch {
            XCTFail("expected runtime error, got \(error)")
        }
    }

    // MARK: Path tracking

    func testPathOnlyQueryTracksSourceNodes() async throws {
        let idx = index(from: sampleDoc)
        let engine = QueryEngine()
        let result = try await engine.run(".users[] | select(.age > 30) | .name", on: idx)

        // Source node IDs are present and each projects back to its output value.
        let ids = try XCTUnwrap(result.sourceNodeIDs)
        XCTAssertEqual(ids.count, result.values.count)
        XCTAssertEqual(ids.map { JQValue(node: $0, in: idx) }, result.values)
    }

    func testPathOnlyIterateTracksSourceNodes() async throws {
        let idx = index(from: sampleDoc)
        let engine = QueryEngine()
        let result = try await engine.run(".users[] | .age", on: idx)
        XCTAssertEqual(result.values, [.int(40), .int(25), .int(35)])
        let ids = try XCTUnwrap(result.sourceNodeIDs)
        XCTAssertEqual(ids.map { JQValue(node: $0, in: idx) }, result.values)
    }

    func testConstructingQueryIsNotPathOnly() async throws {
        let engine = QueryEngine()
        let result = try await engine.run("[.users[].name]", on: index(from: sampleDoc))
        XCTAssertEqual(result.values, [.array([.string("alice"), .string("bob"), .string("carol")])])
        XCTAssertNil(result.sourceNodeIDs)
    }

    func testObjectConstructIsNotPathOnly() async throws {
        let engine = QueryEngine()
        let result = try await engine.run(".users[] | {n: .name}", on: index(from: sampleDoc))
        XCTAssertNil(result.sourceNodeIDs)
        XCTAssertEqual(result.values.count, 3)
    }
}
