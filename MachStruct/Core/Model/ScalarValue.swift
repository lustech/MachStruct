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
