import SwiftUI

/// The MachStruct brand icon drawn with SwiftUI shapes.
///
/// Replicates the `favicon.svg` exactly: dark rounded-rect background,
/// subtle border, two blue lines, and three node circles.
/// Scales to any `size` — defaults to 64 pt.
struct MachStructIcon: View {

    var size: CGFloat = 64

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width

            // ── Background ────────────────────────────────────────────────
            let cornerRadius = s * (7.0 / 32.0)
            var bgPath = Path(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                              cornerRadius: cornerRadius)
            ctx.fill(bgPath, with: .color(Color(hex: 0x0c1828)))

            // ── Border ────────────────────────────────────────────────────
            let inset = s / 64.0
            bgPath = Path(roundedRect: CGRect(x: inset, y: inset,
                                              width: s - inset * 2,
                                              height: s - inset * 2),
                          cornerRadius: cornerRadius - inset)
            ctx.stroke(bgPath,
                       with: .color(Color(hex: 0x1e3a5f)),
                       lineWidth: s / 32.0)

            // Helper: convert SVG coordinates (top-left origin, 32×32 viewBox) to Canvas space.
            func pt(_ svgX: CGFloat, _ svgY: CGFloat) -> CGPoint {
                CGPoint(x: svgX / 32.0 * s, y: svgY / 32.0 * s)
            }

            // ── Lines ─────────────────────────────────────────────────────
            var linePath = Path()
            linePath.move(to: pt(16, 9))
            linePath.addLine(to: pt(8, 20))
            linePath.move(to: pt(16, 9))
            linePath.addLine(to: pt(24, 20))
            ctx.stroke(linePath,
                       with: .color(Color(hex: 0x60a5fa)),
                       style: StrokeStyle(lineWidth: 2.0 / 32.0 * s,
                                          lineCap: .round))

            // ── Circles ───────────────────────────────────────────────────
            func circlePath(cx: CGFloat, cy: CGFloat, r: CGFloat) -> Path {
                let rs = r / 32.0 * s
                let c  = pt(cx, cy)
                return Path(ellipseIn: CGRect(x: c.x - rs, y: c.y - rs,
                                             width: rs * 2, height: rs * 2))
            }
            ctx.fill(circlePath(cx: 16, cy: 9,  r: 3),   with: .color(Color(hex: 0x60a5fa)))
            ctx.fill(circlePath(cx: 8,  cy: 21, r: 2.5), with: .color(Color(hex: 0x93c5fd)))
            ctx.fill(circlePath(cx: 24, cy: 21, r: 2.5), with: .color(Color(hex: 0x93c5fd)))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * (7.0 / 32.0)))
    }
}

// MARK: - Color hex helper

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8)  & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: 20) {
        MachStructIcon(size: 32)
        MachStructIcon(size: 64)
        MachStructIcon(size: 128)
    }
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
}
