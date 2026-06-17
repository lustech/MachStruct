import XCTest
@testable import MachStructCore

// MARK: - JQParser

final class JQParserTests: XCTestCase {

    private func parse(_ src: String) throws -> JQExpr {
        try JQParser.parse(src)
    }

    // MARK: Paths

    func testIdentity() throws {
        XCTAssertEqual(try parse("."), .identity)
    }

    func testField() throws {
        XCTAssertEqual(try parse(".foo"),
                       .field(base: .identity, name: "foo", optional: false))
    }

    func testNestedField() throws {
        XCTAssertEqual(try parse(".foo.bar"),
                       .field(base: .field(base: .identity, name: "foo", optional: false),
                              name: "bar", optional: false))
    }

    func testOptionalField() throws {
        XCTAssertEqual(try parse(".foo?"),
                       .field(base: .identity, name: "foo", optional: true))
    }

    func testIndex() throws {
        XCTAssertEqual(try parse(".[0]"),
                       .index(base: .identity, index: .literal(.int(0)), optional: false))
    }

    func testFieldThenIndex() throws {
        XCTAssertEqual(try parse(".foo[0]"),
                       .index(base: .field(base: .identity, name: "foo", optional: false),
                              index: .literal(.int(0)), optional: false))
    }

    func testIterate() throws {
        XCTAssertEqual(try parse(".[]"), .iterate(base: .identity, optional: false))
    }

    func testFieldIterate() throws {
        XCTAssertEqual(try parse(".foo[]"),
                       .iterate(base: .field(base: .identity, name: "foo", optional: false),
                                optional: false))
    }

    func testSlice() throws {
        XCTAssertEqual(try parse(".[1:3]"),
                       .slice(base: .identity,
                              lower: .literal(.int(1)), upper: .literal(.int(3)),
                              optional: false))
    }

    // MARK: Operators & precedence

    func testPipe() throws {
        XCTAssertEqual(try parse(".a | .b"),
                       .pipe(.field(base: .identity, name: "a", optional: false),
                             .field(base: .identity, name: "b", optional: false)))
    }

    func testCommaBindsTighterThanPipe() throws {
        // .a, .b | .c  ==  (.a, .b) | .c
        let result = try parse(".a, .b | .c")
        guard case .pipe(let lhs, _) = result else {
            return XCTFail("expected pipe at top level, got \(result)")
        }
        guard case .comma = lhs else {
            return XCTFail("expected comma on the left of the pipe, got \(lhs)")
        }
    }

    func testComparison() throws {
        XCTAssertEqual(try parse(".age > 30"),
                       .binary(op: .gt,
                               lhs: .field(base: .identity, name: "age", optional: false),
                               rhs: .literal(.int(30))))
    }

    func testArithmeticPrecedence() throws {
        // .a + .b * .c  ==  .a + (.b * .c)
        let result = try parse(".a + .b * .c")
        guard case .binary(.add, _, let rhs) = result else {
            return XCTFail("expected add at top, got \(result)")
        }
        guard case .binary(.mul, _, _) = rhs else {
            return XCTFail("expected mul on the right, got \(rhs)")
        }
    }

    func testAndOrPrecedence() throws {
        // .a and .b or .c  ==  (.a and .b) or .c
        let result = try parse(".a and .b or .c")
        guard case .or(let lhs, _) = result else {
            return XCTFail("expected or at top, got \(result)")
        }
        guard case .and = lhs else {
            return XCTFail("expected and on the left, got \(lhs)")
        }
    }

    // MARK: Literals

    func testLiterals() throws {
        XCTAssertEqual(try parse("true"), .literal(.bool(true)))
        XCTAssertEqual(try parse("false"), .literal(.bool(false)))
        XCTAssertEqual(try parse("null"), .literal(.null))
        XCTAssertEqual(try parse("42"), .literal(.int(42)))
        XCTAssertEqual(try parse("3.5"), .literal(.double(3.5)))
        XCTAssertEqual(try parse("\"hi\""), .literal(.string("hi")))
        XCTAssertEqual(try parse("-7"), .literal(.int(-7)))
    }

    // MARK: Construction

    func testArrayConstruct() throws {
        XCTAssertEqual(try parse("[]"), .array(nil))
        XCTAssertEqual(try parse("[.a]"),
                       .array(.field(base: .identity, name: "a", optional: false)))
    }

    func testObjectConstruct() throws {
        XCTAssertEqual(
            try parse("{a: .x}"),
            .object([JQObjectEntry(key: .literal(.string("a")),
                                   value: .field(base: .identity, name: "x", optional: false))])
        )
    }

    func testObjectShorthand() throws {
        // {foo} is sugar for {foo: .foo}
        XCTAssertEqual(
            try parse("{foo}"),
            .object([JQObjectEntry(key: .literal(.string("foo")),
                                   value: .field(base: .identity, name: "foo", optional: false))])
        )
    }

    // MARK: Builtins

    func testCallNoArgs() throws {
        XCTAssertEqual(try parse("length"), .call(name: "length", args: []))
        XCTAssertEqual(try parse("keys"), .call(name: "keys", args: []))
    }

    func testCallWithArg() throws {
        XCTAssertEqual(
            try parse("select(.age > 30)"),
            .call(name: "select",
                  args: [.binary(op: .gt,
                                 lhs: .field(base: .identity, name: "age", optional: false),
                                 rhs: .literal(.int(30)))])
        )
    }

    func testParenGrouping() throws {
        XCTAssertEqual(try parse("(.a)"),
                       .field(base: .identity, name: "a", optional: false))
    }

    func testFlagshipQueryParses() throws {
        // .users[] | select(.age > 30) | .name
        XCTAssertNoThrow(try parse(".users[] | select(.age > 30) | .name"))
    }

    // MARK: Errors

    func testErrorUnterminatedIndex() {
        XCTAssertThrowsError(try parse(".[")) { error in
            XCTAssertTrue(error is JQParseError)
        }
    }

    func testErrorTrailingTokens() {
        // Two juxtaposed primaries with no operator between them is invalid.
        XCTAssertThrowsError(try parse("1 2"))
    }

    func testErrorEmptyQuery() {
        XCTAssertThrowsError(try parse(""))
    }

    func testErrorUnterminatedString() {
        XCTAssertThrowsError(try parse("\"oops"))
    }
}
