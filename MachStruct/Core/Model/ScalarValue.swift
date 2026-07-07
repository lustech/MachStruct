import Foundation

/// A fully parsed leaf value.
public enum ScalarValue: Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case boolean(Bool)
    case null

    /// Display string for the UI tree row.
    public var displayText: String {
        switch self {
        case .string(let s):   return "\"\(s)\""
        case .integer(let n):  return "\(n)"
        case .float(let f):    return _formatDouble(f)
        case .boolean(let b):  return b ? "true" : "false"
        case .null:            return "null"
        }
    }

    /// Unquoted text used for full-text search matching.
    ///
    /// Unlike `displayText`, string values are returned without surrounding
    /// double-quotes so that searching for `alice` matches `"alice"`.
    public var searchableText: String {
        switch self {
        case .string(let s):   return s
        case .integer(let n):  return "\(n)"
        case .float(let f):    return _formatDouble(f)
        case .boolean(let b):  return b ? "true" : "false"
        case .null:            return "null"
        }
    }

    /// Short type badge label shown in tree rows ("str", "int", "num", "bool", "null").
    public var typeBadge: String {
        switch self {
        case .string:   return "str"
        case .integer:  return "int"
        case .float:    return "num"
        case .boolean:  return "bool"
        case .null:     return "null"
        }
    }
}

// MARK: - Foundation JSON bridging

public extension ScalarValue {
    /// Convert a `JSONSerialization`-produced value (`NSNumber`, `NSString`,
    /// `NSNull`, …) to a `ScalarValue`.
    ///
    /// The boolean check must use `CFBooleanGetTypeID` — a plain `as? Bool`
    /// cast succeeds for `NSNumber(0)`/`NSNumber(1)` and would corrupt the
    /// JSON numbers `0` and `1` into `false`/`true`.
    init(jsonAny any: Any) {
        if let n = any as? NSNumber {
            // NSNumber covers native Bool via bridging; CFBoolean type check
            // is the only reliable discriminator.
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() {
                self = .boolean(n.boolValue)
            } else if String(cString: n.objCType) == "Q" {
                // JSONSerialization types numbers ≥ 2^63 as unsigned 64-bit;
                // int64Value would bit-wrap them negative. Values beyond
                // Int64.max degrade to float (sign- and magnitude-correct).
                let u = n.uint64Value
                self = u <= UInt64(Int64.max) ? .integer(Int64(u))
                                              : .float(n.doubleValue)
            } else if n.doubleValue.truncatingRemainder(dividingBy: 1) == 0,
                      n.doubleValue >= Double(Int64.min),
                      n.doubleValue <= Double(Int64.max) {
                self = .integer(n.int64Value)
            } else {
                self = .float(n.doubleValue)
            }
        } else if let s = any as? String {
            self = .string(s)
        } else if any is NSNull {
            self = .null
        } else if let b = any as? Bool {
            self = .boolean(b)   // non-Foundation Bool (defensive)
        } else {
            self = .string(String(describing: any))
        }
    }
}

// MARK: - Parsing helper

/// Infers the most appropriate `ScalarValue` from free-form text input.
///
/// Priority: null → boolean → integer → float → string.
/// Strips surrounding double-quotes if present (e.g. `"hello"` → `hello`).
public func parseScalarValue(_ text: String) -> ScalarValue {
    let t = text.trimmingCharacters(in: .whitespaces)
    if t.lowercased() == "null"  { return .null }
    if t.lowercased() == "true"  { return .boolean(true) }
    if t.lowercased() == "false" { return .boolean(false) }
    if let i = Int64(t)          { return .integer(i) }
    if let f = Double(t)         { return .float(f) }
    if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
        return .string(String(t.dropFirst().dropLast()))
    }
    return .string(t)
}

private func _formatDouble(_ value: Double) -> String {
    if value.isNaN      { return "NaN" }
    if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
    // Show at least one decimal place so it's distinguishable from integer display
    if value.truncatingRemainder(dividingBy: 1) == 0 {
        return String(format: "%.1f", value)
    }
    return String(value)
}
