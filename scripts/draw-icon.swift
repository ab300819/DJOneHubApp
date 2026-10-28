// Regenerates the app icon master. Usage:
//   swiftc -O scripts/draw-icon.swift -o /tmp/draw-icon && /tmp/draw-icon icon-1024.png
// then scale it into Resources/Assets.xcassets/AppIcon.appiconset with sips.
import AppKit
import CoreGraphics

// Draws the 1024 px master icon following the macOS grid: an 824 px squircle
// centred in the canvas, so the system adds nothing and nothing is clipped.
let size = 1024.0
let inset = 100.0
let out = CommandLine.arguments[1]

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Soft drop shadow, as system icons carry.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
ctx.addPath(shape); ctx.setFillColor(CGColor(red: 0.04, green: 0.20, blue: 0.55, alpha: 1)); ctx.fillPath()
ctx.restoreGState()

// Background: deep blue gradient.
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let gradient = CGGradient(colorsSpace: space, colors: [
    CGColor(red: 0.16, green: 0.47, blue: 1.00, alpha: 1),
    CGColor(red: 0.03, green: 0.20, blue: 0.62, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
ctx.restoreGState()

let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

// Cellular signal bars above the text, rising left to right.
ctx.setFillColor(white)
let barWidth = 62.0, gap = 34.0, baseY = 560.0
let heights = [70.0, 120.0, 170.0, 220.0]
let total = Double(heights.count) * barWidth + Double(heights.count - 1) * gap
for (i, h) in heights.enumerated() {
    let x = size / 2 - total / 2 + Double(i) * (barWidth + gap)
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: baseY, width: barWidth, height: h),
                       cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.fillPath()
}

// "4G" in heavy rounded system type.
let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = gc
var font = NSFont.systemFont(ofSize: 330, weight: .heavy)
if let rounded = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: rounded, size: 330)! }
let text = NSAttributedString(string: "4G", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: -6])
let bounds = text.boundingRect(with: .zero, options: [.usesLineFragmentOrigin])
text.draw(at: CGPoint(x: (size - bounds.width) / 2, y: 175))

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
