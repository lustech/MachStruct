import Foundation

// MARK: - JQRuntimeError

/// A runtime error raised while evaluating a jq filter (type mismatch, division
/// by zero, unknown function, …).  Distinct from `JQParseError`, which is raised
/// before evaluation begins.
public struct JQRuntimeError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

// MARK: - JQEvaluator

/// Evaluates a parsed `JQExpr` against an input value, producing a stream of
/// output values (jq filters emit zero or more outputs per input).
///
/// Pure and `Sendable`.  Long-running evaluations should be checked for
/// cancellation by the caller (`QueryEngine`) between top-level outputs; the
/// evaluator itself does not block.
public enum JQEvaluator {

    public static func evaluate(_ expr: JQExpr, against input: JQValue) throws -> [JQValue] {
        switch expr {
        case .identity:
            return [input]

        case .literal(let v):
            return [v]

        case .field(let base, let name, let optional):
            return try evaluate(base, against: input).flatMap { b -> [JQValue] in
                try fieldAccess(b, name: name, optional: optional)
            }

        case .index(let base, let indexExpr, let optional):
            let bases = try evaluate(base, against: input)
            let indices = try evaluate(indexExpr, against: input)
            var out: [JQValue] = []
            for b in bases {
                for idx in indices {
                    if let v = try indexAccess(b, index: idx, optional: optional) {
                        out.append(v)
                    }
                }
            }
            return out

        case .slice(let base, let lowerExpr, let upperExpr, let optional):
            let bases = try evaluate(base, against: input)
            let lowers = try lowerExpr.map { try evaluate($0, against: input) } ?? [.null]
            let uppers = try upperExpr.map { try evaluate($0, against: input) } ?? [.null]
            var out: [JQValue] = []
            for b in bases {
                for lo in lowers {
                    for hi in uppers {
                        if let v = try sliceAccess(b, lower: lo, upper: hi, optional: optional) {
                            out.append(v)
                        }
                    }
                }
            }
            return out

        case .iterate(let base, let optional):
            return try evaluate(base, against: input).flatMap { b -> [JQValue] in
                try iterate(b, optional: optional)
            }

        case .pipe(let lhs, let rhs):
            var out: [JQValue] = []
            for o in try evaluate(lhs, against: input) {
                out.append(contentsOf: try evaluate(rhs, against: o))
            }
            return out

        case .comma(let lhs, let rhs):
            return try evaluate(lhs, against: input) + evaluate(rhs, against: input)

        case .binary(let op, let lhs, let rhs):
            let ls = try evaluate(lhs, against: input)
            let rs = try evaluate(rhs, against: input)
            var out: [JQValue] = []
            for l in ls {
                for r in rs {
                    out.append(try applyBinary(op, l, r))
                }
            }
            return out

        case .and(let lhs, let rhs):
            var out: [JQValue] = []
            for l in try evaluate(lhs, against: input) {
                if !truthy(l) { out.append(.bool(false)) }
                else { out.append(contentsOf: try evaluate(rhs, against: input).map { .bool(truthy($0)) }) }
            }
            return out

        case .or(let lhs, let rhs):
            var out: [JQValue] = []
            for l in try evaluate(lhs, against: input) {
                if truthy(l) { out.append(.bool(true)) }
                else { out.append(contentsOf: try evaluate(rhs, against: input).map { .bool(truthy($0)) }) }
            }
            return out

        case .negate(let e):
            return try evaluate(e, against: input).map { v in
                switch v {
                case .int(let n):    return .int(-n)
                case .double(let d): return .double(-d)
                default:             return v
                }
            }

        case .array(let inner):
            guard let inner else { return [.array([])] }
            return [.array(try evaluate(inner, against: input))]

        case .object(let entries):
            return try evaluateObject(entries, against: input)

        case .call(let name, let args):
            return try evaluateCall(name: name, args: args, input: input)
        }
    }

    // MARK: - Path helpers

    private static func fieldAccess(_ value: JQValue, name: String, optional: Bool) throws -> [JQValue] {
        switch value {
        case .object(let members):
            return [members.first(where: { $0.key == name })?.value ?? .null]
        case .null:
            return [.null]
        default:
            if optional { return [] }
            throw JQRuntimeError("Cannot index \(value.typeName) with \"\(name)\"")
        }
    }

    private static func indexAccess(_ value: JQValue, index: JQValue, optional: Bool) throws -> JQValue? {
        switch (value, index) {
        case (.array(let arr), .int(let i)):
            let n = arr.count
            let idx = i < 0 ? Int(i) + n : Int(i)
            return (idx >= 0 && idx < n) ? arr[idx] : .null
        case (.array(let arr), .double(let d)):
            let n = arr.count
            let i = Int(d)
            let idx = i < 0 ? i + n : i
            return (idx >= 0 && idx < n) ? arr[idx] : .null
        case (.object(let members), .string(let key)):
            return members.first(where: { $0.key == key })?.value ?? .null
        case (.null, _):
            return .null
        default:
            if optional { return nil }
            throw JQRuntimeError("Cannot index \(value.typeName) with \(index.typeName)")
        }
    }

    private static func sliceAccess(_ value: JQValue, lower: JQValue, upper: JQValue, optional: Bool) throws -> JQValue? {
        func bound(_ v: JQValue, default def: Int, count: Int) -> Int {
            let raw: Int
            switch v {
            case .int(let i):    raw = Int(i)
            case .double(let d): raw = Int(d)
            case .null:          return def
            default:             return def
            }
            let adjusted = raw < 0 ? raw + count : raw
            return Swift.max(0, Swift.min(adjusted, count))
        }
        switch value {
        case .array(let arr):
            let lo = bound(lower, default: 0, count: arr.count)
            let hi = bound(upper, default: arr.count, count: arr.count)
            return .array(lo < hi ? Array(arr[lo..<hi]) : [])
        case .string(let s):
            let chars = Array(s)
            let lo = bound(lower, default: 0, count: chars.count)
            let hi = bound(upper, default: chars.count, count: chars.count)
            return .string(lo < hi ? String(chars[lo..<hi]) : "")
        case .null:
            return .null
        default:
            if optional { return nil }
            throw JQRuntimeError("Cannot slice \(value.typeName)")
        }
    }

    private static func iterate(_ value: JQValue, optional: Bool) throws -> [JQValue] {
        switch value {
        case .array(let arr):     return arr
        case .object(let members): return members.map { $0.value }
        default:
            if optional { return [] }
            throw JQRuntimeError("Cannot iterate over \(value.typeName)")
        }
    }

    // MARK: - Object construction

    private static func evaluateObject(_ entries: [JQObjectEntry], against input: JQValue) throws -> [JQValue] {
        var partials: [[(key: String, value: JQValue)]] = [[]]
        for entry in entries {
            let keys = try evaluate(entry.key, against: input)
            let values = try evaluate(entry.value, against: input)
            var next: [[(key: String, value: JQValue)]] = []
            for partial in partials {
                for key in keys {
                    guard case .string(let k) = key else {
                        throw JQRuntimeError("Object keys must be strings, got \(key.typeName)")
                    }
                    for value in values {
                        next.append(partial + [(k, value)])
                    }
                }
            }
            partials = next
        }
        return partials.map { .object($0) }
    }

    // MARK: - Binary operators

    private static func applyBinary(_ op: JQBinaryOp, _ l: JQValue, _ r: JQValue) throws -> JQValue {
        switch op {
        case .eq:  return .bool(l == r)
        case .neq: return .bool(l != r)
        case .lt:  return .bool(compare(l, r) < 0)
        case .le:  return .bool(compare(l, r) <= 0)
        case .gt:  return .bool(compare(l, r) > 0)
        case .ge:  return .bool(compare(l, r) >= 0)
        case .add: return try add(l, r)
        case .sub: return try numericOp(l, r, "-", { $0 - $1 }, { $0 - $1 })
        case .mul: return try numericOp(l, r, "*", { $0 * $1 }, { $0 * $1 })
        case .div:
            guard let rd = asDouble(r), rd != 0 else { throw JQRuntimeError("Division by zero") }
            guard let ld = asDouble(l) else { throw JQRuntimeError("Cannot divide \(l.typeName)") }
            return .double(ld / rd)
        }
    }

    private static func add(_ l: JQValue, _ r: JQValue) throws -> JQValue {
        switch (l, r) {
        case (.null, _): return r
        case (_, .null): return l
        case (.int(let a), .int(let b)):       return .int(a + b)
        case (.string(let a), .string(let b)): return .string(a + b)
        case (.array(let a), .array(let b)):   return .array(a + b)
        case (.object(let a), .object(let b)):
            // Right-biased merge, preserving order (left members first).
            var merged = a.filter { lm in !b.contains(where: { $0.key == lm.key }) }
            merged.append(contentsOf: b)
            return .object(merged)
        default:
            if let a = asDouble(l), let b = asDouble(r) { return .double(a + b) }
            throw JQRuntimeError("Cannot add \(l.typeName) and \(r.typeName)")
        }
    }

    private static func numericOp(_ l: JQValue, _ r: JQValue, _ sym: String,
                                  _ intOp: (Int64, Int64) -> Int64,
                                  _ dblOp: (Double, Double) -> Double) throws -> JQValue {
        if case .int(let a) = l, case .int(let b) = r { return .int(intOp(a, b)) }
        guard let a = asDouble(l), let b = asDouble(r) else {
            throw JQRuntimeError("Cannot \(sym) \(l.typeName) and \(r.typeName)")
        }
        return .double(dblOp(a, b))
    }

    // MARK: - Builtins

    private static func evaluateCall(name: String, args: [JQExpr], input: JQValue) throws -> [JQValue] {
        switch (name, args.count) {
        case ("length", 0):
            return [.int(Int64(length(input)))]

        case ("keys", 0):
            return [.array(try keys(input, sorted: true))]
        case ("keys_unsorted", 0):
            return [.array(try keys(input, sorted: false))]

        case ("values", 0):
            return input == .null ? [] : [input]

        case ("type", 0):
            return [.string(input.typeName)]

        case ("not", 0):
            return [.bool(!truthy(input))]

        case ("has", 1):
            return try evaluate(args[0], against: input).map { key in
                .bool(has(input, key: key))
            }

        case ("select", 1):
            var out: [JQValue] = []
            for v in try evaluate(args[0], against: input) where truthy(v) {
                out.append(input)
            }
            return out

        case ("map", 1):
            let arr = try requireArray(input, "map")
            var collected: [JQValue] = []
            for element in arr {
                collected.append(contentsOf: try evaluate(args[0], against: element))
            }
            return [.array(collected)]

        case ("add", 0):
            let arr = try requireArray(input, "add")
            guard var acc = arr.first else { return [.null] }
            for v in arr.dropFirst() { acc = try add(acc, v) }
            return [acc]

        case ("min", 0):
            let arr = try requireArray(input, "min")
            return [arr.min(by: { compare($0, $1) < 0 }) ?? .null]
        case ("max", 0):
            let arr = try requireArray(input, "max")
            return [arr.max(by: { compare($0, $1) < 0 }) ?? .null]

        case ("sort", 0):
            let arr = try requireArray(input, "sort")
            return [.array(arr.sorted { compare($0, $1) < 0 })]

        case ("sort_by", 1):
            let arr = try requireArray(input, "sort_by")
            let keyed = try arr.map { element -> (key: JQValue, value: JQValue) in
                let k = try evaluate(args[0], against: element).first ?? .null
                return (k, element)
            }
            let sorted = keyed.enumerated().sorted { a, b in
                let c = compare(a.element.key, b.element.key)
                return c != 0 ? c < 0 : a.offset < b.offset   // stable
            }
            return [.array(sorted.map { $0.element.value })]

        case ("unique", 0):
            let arr = try requireArray(input, "unique")
            let sorted = arr.sorted { compare($0, $1) < 0 }
            var result: [JQValue] = []
            for v in sorted where result.last != v { result.append(v) }
            return [.array(result)]

        case ("contains", 1):
            let other = try evaluate(args[0], against: input).first ?? .null
            return [.bool(contains(input, other))]

        case ("startswith", 1):
            let s = try requireString(input, "startswith")
            let pfx = try requireStringArg(args[0], input, "startswith")
            return [.bool(s.hasPrefix(pfx))]
        case ("endswith", 1):
            let s = try requireString(input, "endswith")
            let sfx = try requireStringArg(args[0], input, "endswith")
            return [.bool(s.hasSuffix(sfx))]

        case ("test", 1):
            let s = try requireString(input, "test")
            let pattern = try requireStringArg(args[0], input, "test")
            return [.bool(regexMatches(pattern, in: s))]

        case ("ascii_downcase", 0):
            return [.string(try requireString(input, "ascii_downcase").lowercased())]
        case ("ascii_upcase", 0):
            return [.string(try requireString(input, "ascii_upcase").uppercased())]

        default:
            throw JQRuntimeError("Unknown function \(name)/\(args.count)")
        }
    }

    // MARK: - Builtin helpers

    private static func length(_ v: JQValue) -> Int {
        switch v {
        case .null:                return 0
        case .bool:                return 0
        case .int, .double:        return 0
        case .string(let s):       return s.count
        case .array(let a):        return a.count
        case .object(let m):       return m.count
        }
    }

    private static func keys(_ v: JQValue, sorted: Bool) throws -> [JQValue] {
        switch v {
        case .object(let members):
            let ks = members.map { $0.key }
            return (sorted ? ks.sorted() : ks).map { .string($0) }
        case .array(let arr):
            return (0..<arr.count).map { .int(Int64($0)) }
        default:
            throw JQRuntimeError("\(v.typeName) has no keys")
        }
    }

    private static func has(_ v: JQValue, key: JQValue) -> Bool {
        switch (v, key) {
        case (.object(let m), .string(let k)): return m.contains { $0.key == k }
        case (.array(let a), .int(let i)):     return i >= 0 && Int(i) < a.count
        default:                               return false
        }
    }

    private static func contains(_ haystack: JQValue, _ needle: JQValue) -> Bool {
        switch (haystack, needle) {
        case (.string(let h), .string(let n)):
            return h.contains(n) || n.isEmpty
        case (.array(let h), .array(let n)):
            return n.allSatisfy { ne in h.contains { contains($0, ne) || $0 == ne } }
        case (.object(let h), .object(let n)):
            return n.allSatisfy { nm in
                h.first(where: { $0.key == nm.key }).map { contains($0.value, nm.value) || $0.value == nm.value } ?? false
            }
        default:
            return haystack == needle
        }
    }

    private static func requireArray(_ v: JQValue, _ fn: String) throws -> [JQValue] {
        guard case .array(let a) = v else {
            throw JQRuntimeError("\(fn) requires an array, got \(v.typeName)")
        }
        return a
    }

    private static func requireString(_ v: JQValue, _ fn: String) throws -> String {
        guard case .string(let s) = v else {
            throw JQRuntimeError("\(fn) requires a string, got \(v.typeName)")
        }
        return s
    }

    private static func requireStringArg(_ expr: JQExpr, _ input: JQValue, _ fn: String) throws -> String {
        guard case .string(let s)? = try evaluate(expr, against: input).first else {
            throw JQRuntimeError("\(fn) argument must be a string")
        }
        return s
    }

    private static func regexMatches(_ pattern: String, in string: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(string.startIndex..., in: string)
        return re.firstMatch(in: string, range: range) != nil
    }

    // MARK: - Truthiness & ordering

    private static func truthy(_ v: JQValue) -> Bool {
        switch v {
        case .null, .bool(false): return false
        default:                  return true
        }
    }

    private static func asDouble(_ v: JQValue) -> Double? {
        switch v {
        case .int(let i):    return Double(i)
        case .double(let d): return d
        default:             return nil
        }
    }

    /// jq's total order: null < false < true < numbers < strings < arrays < objects.
    private static func compare(_ a: JQValue, _ b: JQValue) -> Int {
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb ? -1 : 1 }
        switch (a, b) {
        case (.bool(let x), .bool(let y)):
            return x == y ? 0 : (!x ? -1 : 1)
        case (.string(let x), .string(let y)):
            return x == y ? 0 : (x < y ? -1 : 1)
        case (.array(let x), .array(let y)):
            for (ex, ey) in zip(x, y) {
                let c = compare(ex, ey)
                if c != 0 { return c }
            }
            return x.count == y.count ? 0 : (x.count < y.count ? -1 : 1)
        case (.object(let x), .object(let y)):
            let kx = x.map { $0.key }.sorted(), ky = y.map { $0.key }.sorted()
            if kx != ky { return kx.lexicographicallyPrecedes(ky) ? -1 : 1 }
            return 0
        default:
            // Both numbers.
            let dx = asDouble(a) ?? 0, dy = asDouble(b) ?? 0
            return dx == dy ? 0 : (dx < dy ? -1 : 1)
        }
    }

    private static func rank(_ v: JQValue) -> Int {
        switch v {
        case .null:           return 0
        case .bool:           return 1
        case .int, .double:   return 2
        case .string:         return 3
        case .array:          return 4
        case .object:         return 5
        }
    }
}
