// Makes the Mac app icon from the iPhone one. iOS cuts the rounded corners
// itself; macOS does not, and expects the artwork inside Apple's Mac icon
// grid: an 824-point rounded square centred on a 1024 canvas, with a soft
// shadow below. Same lantern, same glow, Mac shape.
// Run: swift scripts/make-mac-icon.swift <icon-1024.png> <out-mac-1024.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let input = URL(fileURLWithPath: args.count > 1 ? args[1] : "Lantern/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
let output = URL(fileURLWithPath: args.count > 2 ? args[2] : "mac-1024.png")

guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let art = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("cannot read \(input.path)") }

let size = 1024.0
let inset = 100.0
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius = tile.width * 0.225
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let shape = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

// The shadow, drawn once under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(colorSpace: space, components: [0, 0, 0, 0.35])!)
ctx.addPath(shape)
ctx.setFillColor(CGColor(colorSpace: space, components: [0.06, 0.075, 0.095, 1])!)
ctx.fillPath()
ctx.restoreGState()

// The artwork, scaled into the tile and clipped to its corners.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(art, in: tile)
ctx.restoreGState()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(output.path)")
