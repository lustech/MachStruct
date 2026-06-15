import XCTest
@testable import MachStructCore

// MARK: - JQEvaluator conformance

/// Conformance corpus for the jq evaluator: `(input, query, expected outputs)`.
/// Each supported operator and builtin has at least one case, plus error cases.
final class JQEvaluatorTests: XCTestCase {

    private func run(_ query: String, on input: JQValue) throws -> [JQValue] {
        let expr = try JQParser.parse(query)
        return try JQEvaluator.evaluate(expr, against: input)
    }

    private func obj(_ pairs: [(String, JQValue)]) -> JQValue { .object(pairs.map { ($0.0, $0.1) }) }

    // MARK: Paths

    func testIdentity() throws {
        XCTAssertEqual(try run(".", on: .int(5)), [.int(5)])
    }

    func testField() throws {
        XCTAssertEqual(try run(".a", on: obj([("a", .int(1)), ("b", .int(2))])), [.int(1)])
    }

    func testNestedField() throws {
        XCTAssertEqual(try run(".a.b", on: obj([("a", obj([("b", .int(2))]))])), [.int(2)])
    }

    func testMissingFieldIsNull() throws {
        XCTAssertEqual(try run(".z", on: obj([("a", .int(1))])), [.null])
    }

    func testFieldOnNullIsNull() throws {
        XCTAssertEqual(try run(".a", on: .null), [.null])
    }

    func testFieldOnNumberThrows() {
        XCTAssertThrowsError(try run(".a", on: .int(5)))
    }

    func testOptionalFieldSuppressesError() throws {
        XCTAssertEqual(try run(".a?", on: .int(5)), [])
    }

    func testIndex() throws {
        XCTAssertEqual(try run(".[1]", on: .array([.int(10), .int(20), .int(30)])), [.int(20)])
    }

    func testNegativeIndex() throws {
        XCTAssertEqual(try run(".[-1]", on: .array([.int(10), .int(20), .int(30)])), [.int(30)])
    }

    func testIndexOutOfRangeIsNull() throws {
        XCTAssertEqual(try run(".[9]", on: .array([.int(1)])), [.null])
    }

    func testIterateArray() throws {
        XCTAssertEqual(try run(".[]", on: .array([.int(1), .int(2), .int(3)])),
                       [.int(1), .int(2), .int(3)])
    }

    func testIterateObjectYieldsValues() throws {
        XCTAssertEqual(try run(".[]", on: obj([("a", .int(1)), ("b", .int(2))])),
                       [.int(1), .int(2)])
    }

    func testIterateNullThrows() {
        XCTAssertThrowsError(try run(".[]", on: .null))
    }

    func testSlice() throws {
        let input: JQValue = .array([.int(1), .int(2), .int(3), .int(4), .int(5)])
        XCTAssertEqual(try run(".[1:3]", on: input), [.array([.int(2), .int(3)])])
    }

    // MARK: Composition

    func testPipe() throws {
        XCTAssertEqual(try run(".a | .b", on: obj([("a", obj([("b", .int(7))]))])), [.int(7)])
    }

    func testPipeOverStream() throws {
        let input: JQValue = .array([obj([("x", .int(1))]), obj([("x", .int(2))])])
        XCTAssertEqual(try run(".[] | .x", on: input), [.int(1), .int(2)])
    }

    func testComma() throws {
        XCTAssertEqual(try run(".a, .b", on: obj([("a", .int(1)), ("b", .int(2))])),
                       [.int(1), .int(2)])
    }

    // MARK: Comparison & boolean

    func testComparison() throws {
        XCTAssertEqual(try run(".a > 1", on: obj([("a", .int(2))])), [.bool(true)])
        XCTAssertEqual(try run("1 == 1", on: .null), [.bool(true)])
        XCTAssertEqual(try run("1 < 2", on: .null), [.bool(true)])
        XCTAssertEqual(try run("2 != 2", on: .null), [.bool(false)])
    }

    func testAndOr() throws {
        XCTAssertEqual(try run("true and false", on: .null), [.bool(false)])
        XCTAssertEqual(try run("true or false", on: .null), [.bool(true)])
        XCTAssertEqual(try run("null and true", on: .null), [.bool(false)])
    }

    func testNot() throws {
        XCTAssertEqual(try run("true | not", on: .null), [.bool(false)])
        XCTAssertEqual(try run("null | not", on: .null), [.bool(true)])
    }

    // MARK: Arithmetic

    func testIntArithmeticStaysInt() throws {
        XCTAssertEqual(try run("1 + 2", on: .null), [.int(3)])
        XCTAssertEqual(try run("2 * 3", on: .null), [.int(6)])
        XCTAssertEqual(try run("5 - 8", on: .null), [.int(-3)])
    }

    func testDivisionIsDouble() throws {
        XCTAssertEqual(try run("3 / 2", on: .null), [.double(1.5)])
    }

    func testStringConcat() throws {
        XCTAssertEqual(try run("\"a\" + \"b\"", on: .null), [.string("ab")])
    }

    func testArrayConcat() throws {
        XCTAssertEqual(try run("[1] + [2]", on: .null), [.array([.int(1), .int(2)])])
    }

    func testMismatchedAdditionThrows() {
        XCTAssertThrowsError(try run("1 + \"a\"", on: .null))
    }

    // MARK: Literals

    func testLiterals() throws {
        XCTAssertEqual(try run("42", on: .null), [.int(42)])
        XCTAssertEqual(try run("\"x\"", on: .int(99)), [.string("x")])
        XCTAssertEqual(try run("true", on: .null), [.bool(true)])
    }

    // MARK: Construction

    func testArrayConstructCollectsStream() throws {
        XCTAssertEqual(try run("[.a, .b]", on: obj([("a", .int(1)), ("b", .int(2))])),
                       [.array([.int(1), .int(2)])])
        XCTAssertEqual(try run("[.[]]", on: .array([.int(1), .int(2)])),
                       [.array([.int(1), .int(2)])])
        XCTAssertEqual(try run("[]", on: .null), [.array([])])
    }

    func testObjectConstruct() throws {
        XCTAssertEqual(try run("{x: .a}", on: obj([("a", .int(1))])),
                       [obj([("x", .int(1))])])
    }

    func testObjectShorthand() throws {
        XCTAssertEqual(try run("{a, b}", on: obj([("a", .int(1)), ("b", .int(2))])),
                       [obj([("a", .int(1)), ("b", .int(2))])])
    }

    func testObjectConstructOverStreamIsCartesian() throws {
        XCTAssertEqual(try run("{x: .[]}", on: .array([.int(1), .int(2)])),
                       [obj([("x", .int(1))]), obj([("x", .int(2))])])
    }

    // MARK: Builtins

    func testLength() throws {
        XCTAssertEqual(try run("length", on: .array([.int(1), .int(2), .int(3)])), [.int(3)])
        XCTAssertEqual(try run("length", on: .string("abc")), [.int(3)])
        XCTAssertEqual(try run("length", on: obj([("a", .int(1))])), [.int(1)])
        XCTAssertEqual(try run("length", on: .null), [.int(0)])
    }

    func testKeysSorted() throws {
        XCTAssertEqual(try run("keys", on: obj([("b", .int(1)), ("a", .int(2))])),
                       [.array([.string("a"), .string("b")])])
    }

    func testKeysUnsorted() throws {
        XCTAssertEqual(try run("keys_unsorted", on: obj([("b", .int(1)), ("a", .int(2))])),
                       [.array([.string("b"), .string("a")])])
    }

    func testHas() throws {
        XCTAssertEqual(try run("has(\"a\")", on: obj([("a", .int(1))])), [.bool(true)])
        XCTAssertEqual(try run("has(\"z\")", on: obj([("a", .int(1))])), [.bool(false)])
    }

    func testType() throws {
        XCTAssertEqual(try run("type", on: .int(1)), [.string("number")])
        XCTAssertEqual(try run("type", on: .string("x")), [.string("string")])
        XCTAssertEqual(try run("type", on: .array([])), [.string("array")])
    }

    func testSelect() throws {
        XCTAssertEqual(try run("select(.a > 1)", on: obj([("a", .int(2))])),
                       [obj([("a", .int(2))])])
        XCTAssertEqual(try run("select(.a > 1)", on: obj([("a", .int(0))])), [])
    }

    func testMap() throws {
        XCTAssertEqual(try run("map(. + 1)", on: .array([.int(1), .int(2), .int(3)])),
                       [.array([.int(2), .int(3), .int(4)])])
    }

    func testAdd() throws {
        XCTAssertEqual(try run("add", on: .array([.int(1), .int(2), .int(3)])), [.int(6)])
        XCTAssertEqual(try run("add", on: .array([])), [.null])
        XCTAssertEqual(try run("add", on: .array([.string("a"), .string("b")])), [.string("ab")])
    }

    func testMinMax() throws {
        XCTAssertEqual(try run("min", on: .array([.int(3), .int(1), .int(2)])), [.int(1)])
        XCTAssertEqual(try run("max", on: .array([.int(3), .int(1), .int(2)])), [.int(3)])
    }

    func testSort() throws {
        XCTAssertEqual(try run("sort", on: .array([.int(3), .int(1), .int(2)])),
                       [.array([.int(1), .int(2), .int(3)])])
    }

    func testSortBy() throws {
        let input: JQValue = .array([obj([("a", .int(3))]), obj([("a", .int(1))])])
        XCTAssertEqual(try run("sort_by(.a)", on: input),
                       [.array([obj([("a", .int(1))]), obj([("a", .int(3))])])])
    }

    func testUnique() throws {
        XCTAssertEqual(try run("unique", on: .array([.int(3), .int(1), .int(2), .int(1), .int(3)])),
                       [.array([.int(1), .int(2), .int(3)])])
    }

    func testContains() throws {
        XCTAssertEqual(try run("contains(\"oba\")", on: .string("foobar")), [.bool(true)])
        XCTAssertEqual(try run("contains(\"zzz\")", on: .string("foobar")), [.bool(false)])
    }

    func testStartsEndsWith() throws {
        XCTAssertEqual(try run("startswith(\"foo\")", on: .string("foobar")), [.bool(true)])
        XCTAssertEqual(try run("endswith(\"bar\")", on: .string("foobar")), [.bool(true)])
    }

    func testTestRegex() throws {
        XCTAssertEqual(try run("test(\"o+b\")", on: .string("foobar")), [.bool(true)])
        XCTAssertEqual(try run("test(\"^x\")", on: .string("foobar")), [.bool(false)])
    }

    func testAsciiCase() throws {
        XCTAssertEqual(try run("ascii_downcase", on: .string("ABc")), [.string("abc")])
        XCTAssertEqual(try run("ascii_upcase", on: .string("ABc")), [.string("ABC")])
    }

    func testValuesSelectsNonNull() throws {
        // jq's `values` emits its input unless it is null.
        XCTAssertEqual(try run("values", on: .int(1)), [.int(1)])
        XCTAssertEqual(try run("values", on: .null), [])
    }

    func testUnknownFunctionThrows() {
        XCTAssertThrowsError(try run("frobnicate", on: .null))
    }

    // MARK: Flagship query

    func testFlagshipQuery() throws {
        // .users[] | select(.age > 30) | .name
        let users: JQValue = obj([("users", .array([
            obj([("name", .string("alice")), ("age", .int(40))]),
            obj([("name", .string("bob")), ("age", .int(25))]),
            obj([("name", .string("carol")), ("age", .int(35))]),
        ]))])
        XCTAssertEqual(try run(".users[] | select(.age > 30) | .name", on: users),
                       [.string("alice"), .string("carol")])
    }
}
