import XCTest
@testable import MachStructCore

/// A query projects only what `JQDemand` says it reads of its input. Its
/// outputs and errors must be those of evaluating the whole input.
final class JQDemandTests: XCTestCase {

    private enum Outcome: Equatable {
        case values([JQValue])
        case error(String)
    }

    private func outcome(_ expr: JQExpr, _ input: JQValue) -> Outcome {
        do {
            return .values(try JQEvaluator.evaluate(expr, against: input))
        } catch let e as JQRuntimeError {
            return .error(e.message)
        } catch {
            return .error("\(error)")
        }
    }

    private func index(_ value: JQValue) -> NodeIndex {
        let built = value.toDocumentNodes(parentID: nil, depth: 0, key: nil)
        return NodeIndex(rootID: built.root, allNodes: built.nodes)
    }

    private func assertProjectionMatches(_ expr: JQExpr, _ value: JQValue,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let doc = index(value)
        let full = JQValue(node: doc.rootID, in: doc)
        let pruned = JQValue(node: doc.rootID, in: doc, demand: JQDemand.of(expr))
        XCTAssertEqual(outcome(expr, pruned), outcome(expr, full),
                       "\(expr) on \(value)", file: file, line: line)
    }

    // MARK: - Analysis

    func testDemands() throws {
        func demand(_ query: String) throws -> JQDemand { JQDemand.of(try JQParser.parse(query)) }
        let all = JQDemand.all, none = JQDemand.none
        func fields(_ f: [String: JQDemand], each: JQDemand? = nil) -> JQDemand { .parts(fields: f, each: each) }

        XCTAssertEqual(try demand("."), all)
        XCTAssertEqual(try demand("1"), none)
        XCTAssertEqual(try demand(".age"), fields(["age": all]))
        XCTAssertEqual(try demand(".a.b"), fields(["a": fields(["b": all])]))
        XCTAssertEqual(try demand(#".["a"]"#), fields(["a": all]))
        XCTAssertEqual(try demand(".[0]"), all)
        XCTAssertEqual(try demand(".[]"), fields([:], each: all))
        XCTAssertEqual(try demand(".[] | .id"), fields([:], each: fields(["id": all])))
        XCTAssertEqual(try demand(#"select(.city == "x") | .name"#),
                       fields(["city": all, "name": all]))
        XCTAssertEqual(try demand("{n: .name, a: .age}"), fields(["name": all, "age": all]))
        XCTAssertEqual(try demand("map(.id)"), fields([:], each: fields(["id": all])))
        XCTAssertEqual(try demand(".a, .b.c"), fields(["a": all, "b": fields(["c": all])]))
        XCTAssertEqual(try demand(".a | length"), fields(["a": all]))
        XCTAssertEqual(try demand("length"), all)
        XCTAssertEqual(try demand("keys"), all)
        XCTAssertEqual(try demand(".[.k]"), all)
    }

    // MARK: - Equivalence

    private let samples: [JQValue] = [
        .null, .int(3), .string("s"), .array([]), .object([]),
        .array([.object([("name", .string("a")), ("age", .int(30)), ("tags", .array([.string("x")]))]),
                .object([("name", .string("b")), ("age", .null), ("name", .string("dup"))]),
                .int(7), .string("str"), .null, .array([.int(1), .int(2)])]),
        .object([("users", .array([.object([("name", .string("a")), ("k", .string("name"))])])),
                 ("meta", .object([("count", .int(2)), ("a", .object([("b", .int(1))]))])),
                 ("a", .string("shadow")), ("a", .int(2)), ("k", .string("count"))]),
    ]

    private let queries = [
        ".", ".name", ".name?", ".a.b", ".[]", ".[]?", ".[] | .name", ".[] | .name?", ".[0]", ".[-1]",
        #".["name"]"#, #".[]["name"]?"#, ".[] | select(.age > 20) | .name", ".[] | select(.age) | .age",
        ".[] | {n: .name, t: .tags}", ".[] | [.name, .age]", ".[] | .tags[]?", ".[] | .tags | length",
        "map(.name)", "map(.name?)", ".users | map(.name)", ".users[] | .[.k]", ".[] | keys",
        ".meta.a.b, .meta.count", ".[] | values | .name?", ".[] | .name == \"a\"", ".[] | (.age, 0)",
        ".[] | select(.name == \"b\") | .name", ".meta | to_entries", ".[1:]", ".users[0:1] | .[].name",
        "[.[] | .name?] | length", ".[] | .missing.deeper?", ".a", ".a | .b?", "-(.meta.count)",
        ".[] | .age and .name", ".[] | not", ".[] | type", ".users[] | has(\"name\")",
        "\"a\" == .[0].name", ".[] | 30 < .age", ".meta[.k]", ".meta | .[.k]?", "(.[] | .name), (.[] | .age)",
        ".meta.count, (.[] | .a?)", "(.[] | .name?), .[]", ".users[] | .name, (.[] | length)",
    ]

    func testProjectionMatchesTheWholeValue() throws {
        for query in queries {
            guard let expr = try? JQParser.parse(query) else { XCTFail("parse \(query)"); continue }
            for value in samples { assertProjectionMatches(expr, value) }
        }
    }

    func testRandomQueriesMatchTheWholeValue() {
        var rng = SystemRandomNumberGenerator()
        let names = ["a", "b", "name", "k"]
        func value(_ depth: Int) -> JQValue {
            switch Int.random(in: 0..<(depth > 2 ? 4 : 6), using: &rng) {
            case 0: return .null
            case 1: return .int(Int64.random(in: -3...3, using: &rng))
            case 2: return .string(names.randomElement(using: &rng)!)
            case 3: return .bool(Bool.random(using: &rng))
            case 4: return .array((0..<Int.random(in: 0...3, using: &rng)).map { _ in value(depth + 1) })
            default:
                return .object((0..<Int.random(in: 0...3, using: &rng)).map { _ in
                    (names.randomElement(using: &rng)!, value(depth + 1))
                })
            }
        }
        func expr(_ depth: Int) -> JQExpr {
            let name = names.randomElement(using: &rng)!
            let optional = Bool.random(using: &rng)
            if depth > 3 { return Bool.random(using: &rng) ? .identity : .field(base: .identity, name: name, optional: optional) }
            switch Int.random(in: 0..<16, using: &rng) {
            case 0: return .identity
            case 1: return .field(base: expr(depth + 1), name: name, optional: optional)
            case 2: return .index(base: expr(depth + 1), index: .literal(.string(name)), optional: optional)
            case 3: return .index(base: expr(depth + 1), index: .literal(.int(Int64.random(in: -2...2, using: &rng))),
                                  optional: optional)
            case 4: return .iterate(base: expr(depth + 1), optional: optional)
            case 5, 6: return .pipe(expr(depth + 1), expr(depth + 1))
            case 7: return .comma(expr(depth + 1), expr(depth + 1))
            case 8: return .call(name: "select", args: [expr(depth + 1)])
            case 9: return .call(name: "map", args: [expr(depth + 1)])
            case 10: return .array(expr(depth + 1))
            case 11: return .object([JQObjectEntry(key: .literal(.string(name)), value: expr(depth + 1))])
            case 12: return .binary(op: .eq, lhs: expr(depth + 1),
                                    rhs: Bool.random(using: &rng) ? .literal(value(2)) : expr(depth + 1))
            case 13: return .call(name: ["length", "keys", "values", "type", "not"].randomElement(using: &rng)!, args: [])
            case 14: return .index(base: expr(depth + 1), index: expr(depth + 1), optional: optional)
            default: return .and(expr(depth + 1), expr(depth + 1))
            }
        }
        for _ in 0..<3_000 {
            assertProjectionMatches(expr(0), value(0))
        }
    }
}
