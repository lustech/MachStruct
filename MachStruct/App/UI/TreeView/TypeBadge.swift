import SwiftUI

// MARK: - TypeBadge

/// Colored pill badge shown at the right edge of each tree row.
///
/// Colors follow UI-DESIGN.md §3.1:
///   str → green   int → blue    num → purple
///   bool → orange null → gray   obj → teal   arr → indigo
struct TypeBadge: View {

    let style: BadgeStyle

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    // MARK: - Private

    private var label: String {
        switch style {
        case .str:   return "str"
        case .int:   return "int"
        case .float: return "num"
        case .bool:  return "bool"
        case .null:  return "null"
        case .obj:   return "obj"
        case .arr:   return "arr"
        case .err:   return "err"
        }
    }

    private var color: Color {
        switch style {
        case .str:   return .green
        case .int:   return .blue
        case .float: return Color(red: 0.6, green: 0.2, blue: 0.8)   // purple
        case .bool:  return .orange
        case .null:  return Color(white: 0.55)
        case .obj:   return Color(red: 0.15, green: 0.60, blue: 0.55) // teal
        case .arr:   return Color(red: 0.36, green: 0.38, blue: 0.80) // indigo
        case .err:   return .red
        }
    }
}

#Preview {
    HStack(spacing: 6) {
        TypeBadge(style: .str)
        TypeBadge(style: .int)
        TypeBadge(style: .float)
        TypeBadge(style: .bool)
        TypeBadge(style: .null)
        TypeBadge(style: .obj)
        TypeBadge(style: .arr)
    }
    .padding()
}
