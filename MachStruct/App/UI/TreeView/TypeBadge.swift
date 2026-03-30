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
        case .str:          return "str"
        case .int:          return "int"
        case .float:        return "num"
        case .bool:         return "bool"
        case .null:         return "null"
        case .obj:          return "obj"
        case .arr:          return "arr"
        case .err:          return "err"
        case .xml:          return "elm"
        case .ns:           return "ns"
        // YAML secondary badges
        case .yamlAnchor:   return "&"
        case .yamlLiteral:  return "|"
        case .yamlFolded:   return ">"
        case .yamlSingleQ:  return "'"
        case .yamlDoubleQ:  return "\u{201C}"  // left double quotation mark "
        }
    }

    private var color: Color {
        switch style {
        case .str:          return .green
        case .int:          return .blue
        case .float:        return Color(red: 0.6, green: 0.2, blue: 0.8)    // purple
        case .bool:         return .orange
        case .null:         return Color(white: 0.55)
        case .obj:          return Color(red: 0.15, green: 0.60, blue: 0.55) // teal
        case .arr:          return Color(red: 0.36, green: 0.38, blue: 0.80) // indigo
        case .err:          return .red
        case .xml:          return Color(red: 0.80, green: 0.30, blue: 0.20) // coral
        case .ns:           return Color(red: 0.10, green: 0.65, blue: 0.75) // cyan
        // YAML — warm amber for anchors; muted olive/sage for block scalars;
        //        slate tones for quoted strings.
        case .yamlAnchor:   return Color(red: 0.80, green: 0.55, blue: 0.10) // amber
        case .yamlLiteral:  return Color(red: 0.30, green: 0.58, blue: 0.32) // olive green
        case .yamlFolded:   return Color(red: 0.25, green: 0.52, blue: 0.48) // sage
        case .yamlSingleQ:  return Color(red: 0.48, green: 0.48, blue: 0.62) // slate blue-gray
        case .yamlDoubleQ:  return Color(red: 0.52, green: 0.42, blue: 0.62) // slate purple-gray
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
