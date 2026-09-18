// Draws the app icon: a warm dark ground, an amber glow, a simple lantern.
// Run: swift scripts/make-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// Ground
ctx.setFillColor(rgb(0.06, 0.075, 0.095))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Glow: two radial gradients, wide and soft then tight and bright
func glow(radius: Double, inner: CGColor, outer: CGColor) {
    let g = CGGradient(colorsSpace: space, colors: [inner, outer] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: size / 2, y: size * 0.46), startRadius: 0,
                           endCenter: CGPoint(x: size / 2, y: size * 0.46), endRadius: radius, options: [])
}
glow(radius: size * 0.62, inner: rgb(0.95, 0.66, 0.25, 0.50), outer: rgb(0.95, 0.66, 0.25, 0))
glow(radius: size * 0.30, inner: rgb(1.0, 0.85, 0.55, 0.85), outer: rgb(1.0, 0.85, 0.55, 0))

// Lantern body: a rounded rectangle with a cap and a base, drawn as dark on the glow
let bodyW = size * 0.30, bodyH = size * 0.40
let bodyX = (size - bodyW) / 2, bodyY = size * 0.26
let body = CGPath(roundedRect: CGRect(x: bodyX, y: bodyY, width: bodyW, height: bodyH),
                  cornerWidth: size * 0.05, cornerHeight: size * 0.05, transform: nil)
ctx.setStrokeColor(rgb(0.93, 0.95, 0.97))
ctx.setLineWidth(size * 0.032)
ctx.addPath(body)
ctx.strokePath()

// Cap and base
ctx.setFillColor(rgb(0.93, 0.95, 0.97))
ctx.fill(CGRect(x: bodyX - size * 0.02, y: bodyY + bodyH - size * 0.005, width: bodyW + size * 0.04, height: size * 0.05))
ctx.fill(CGRect(x: bodyX - size * 0.02, y: bodyY - size * 0.045, width: bodyW + size * 0.04, height: size * 0.05))
// Handle: an arc above the cap
ctx.setLineWidth(size * 0.028)
ctx.addArc(center: CGPoint(x: size / 2, y: bodyY + bodyH + size * 0.045), radius: size * 0.11,
           startAngle: 0, endAngle: .pi, clockwise: false)
ctx.strokePath()

// Flame: a teardrop in bright amber inside the body
let fx = size / 2, fy = bodyY + bodyH * 0.42
let flame = CGMutablePath()
flame.move(to: CGPoint(x: fx, y: fy + size * 0.13))
flame.addCurve(to: CGPoint(x: fx, y: fy - size * 0.07),
               control1: CGPoint(x: fx + size * 0.11, y: fy + size * 0.02),
               control2: CGPoint(x: fx + size * 0.07, y: fy - size * 0.07))
flame.addCurve(to: CGPoint(x: fx, y: fy + size * 0.13),
               control1: CGPoint(x: fx - size * 0.07, y: fy - size * 0.07),
               control2: CGPoint(x: fx - size * 0.11, y: fy + size * 0.02))
ctx.setFillColor(rgb(1.0, 0.72, 0.30))
ctx.addPath(flame)
ctx.fillPath()
let core = CGMutablePath()
core.addEllipse(in: CGRect(x: fx - size * 0.028, y: fy - size * 0.02, width: size * 0.056, height: size * 0.08))
ctx.setFillColor(rgb(1.0, 0.95, 0.80))
ctx.addPath(core)
ctx.fillPath()

let image = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")
