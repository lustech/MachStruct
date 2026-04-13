#!/usr/bin/env swift
/// Renders the MachStruct brand icon to all required AppIcon PNG sizes.
///
/// Usage:  swift scripts/render_icon.swift
///
/// The icon is drawn directly with CoreGraphics — no external dependencies.
/// Output goes to MachStruct/Assets.xcassets/AppIcon.appiconset/

import AppKit
import CoreGraphics

// MARK: - Drawing

/// Draws the MachStruct logo into `ctx` at the given `size`.
///
/// Replicates the favicon.svg exactly:
///   - Dark rounded-rect background (#0c1828)
///   - Subtle border (#1e3a5f)
///   - Two blue lines from top node to bottom-left and bottom-right
///   - Three circles: top (#60a5fa), bottom-left and bottom-right (#93c5fd)
func drawIcon(in ctx: CGContext, size: CGFloat) {
    let s = size

    // ── Background ────────────────────────────────────────────────────────
    let cornerRadius = s * (7.0 / 32.0)
    let bgColor = CGColor(red: 0.047, green: 0.094, blue: 0.157, alpha: 1)   // #0c1828
    ctx.setFillColor(bgColor)
    let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                        cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                        transform: nil)
    ctx.addPath(bgPath)
    ctx.fillPath()

    // ── Border ────────────────────────────────────────────────────────────
    let borderColor = CGColor(red: 0.118, green: 0.227, blue: 0.373, alpha: 1) // #1e3a5f
    ctx.setStrokeColor(borderColor)
    ctx.setLineWidth(s / 32.0)
    let inset = s / 64.0
    let borderPath = CGPath(roundedRect: CGRect(x: inset, y: inset,
                                                width: s - inset * 2,
                                                height: s - inset * 2),
                            cornerWidth: cornerRadius - inset,
                            cornerHeight: cornerRadius - inset,
                            transform: nil)
    ctx.addPath(borderPath)
    ctx.strokePath()

    // SVG coordinate system is top-left origin; CGContext is bottom-left.
    // Flip: cgY = size - svgY (for a 32×32 viewBox scaled to `size`)
    func pt(_ svgX: CGFloat, _ svgY: CGFloat) -> CGPoint {
        CGPoint(x: svgX / 32.0 * s, y: (32.0 - svgY) / 32.0 * s)
    }

    // ── Lines ─────────────────────────────────────────────────────────────
    let lineColor = CGColor(red: 0.376, green: 0.647, blue: 0.980, alpha: 1) // #60a5fa
    ctx.setStrokeColor(lineColor)
    ctx.setLineWidth(2.0 / 32.0 * s)
    ctx.setLineCap(.round)

    // left line: (16,9) → (8,20)
    ctx.move(to: pt(16, 9))
    ctx.addLine(to: pt(8, 20))
    ctx.strokePath()

    // right line: (16,9) → (24,20)
    ctx.move(to: pt(16, 9))
    ctx.addLine(to: pt(24, 20))
    ctx.strokePath()

    // ── Circles ───────────────────────────────────────────────────────────
    func fillCircle(cx: CGFloat, cy: CGFloat, r: CGFloat, hex: CGColor) {
        ctx.setFillColor(hex)
        let c = pt(cx, cy)
        let rs = r / 32.0 * s
        ctx.fillEllipse(in: CGRect(x: c.x - rs, y: c.y - rs, width: rs * 2, height: rs * 2))
    }

    let blue1 = CGColor(red: 0.376, green: 0.647, blue: 0.980, alpha: 1) // #60a5fa
    let blue2 = CGColor(red: 0.576, green: 0.773, blue: 0.992, alpha: 1) // #93c5fd

    fillCircle(cx: 16, cy: 9,  r: 3,   hex: blue1)  // top node
    fillCircle(cx: 8,  cy: 21, r: 2.5, hex: blue2)  // bottom-left
    fillCircle(cx: 24, cy: 21, r: 2.5, hex: blue2)  // bottom-right
}

// MARK: - Export

let outputDir = "MachStruct/Assets.xcassets/AppIcon.appiconset"

/// (filename, logical-points, scale)
let sizes: [(String, Int, Int)] = [
    ("icon_16x16.png",      16, 1),
    ("icon_16x16@2x.png",   16, 2),
    ("icon_32x32.png",      32, 1),
    ("icon_32x32@2x.png",   32, 2),
    ("icon_64x64.png",      64, 1),
    ("icon_64x64@2x.png",   64, 2),
    ("icon_128x128.png",    128, 1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png",    256, 1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png",    512, 1),
    ("icon_512x512@2x.png", 512, 2),
]

for (filename, pts, scale) in sizes {
    let px = pts * scale
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil,
                              width: px, height: px,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("Failed to create context for \(filename)") }

    drawIcon(in: ctx, size: CGFloat(px))

    guard let cgImage = ctx.makeImage() else { fatalError("Failed to make image for \(filename)") }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: px, height: px))
    guard let tiffData = nsImage.tiffRepresentation,
          let bitmap   = NSBitmapImageRep(data: tiffData),
          let pngData  = bitmap.representation(using: .png, properties: [:])
    else { fatalError("Failed to encode PNG for \(filename)") }

    let url = URL(fileURLWithPath: "\(outputDir)/\(filename)")
    try! pngData.write(to: url)
    print("✓ \(filename) (\(px)×\(px) px)")
}

print("\nDone — all icon sizes written to \(outputDir)/")
