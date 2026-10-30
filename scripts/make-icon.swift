// Draws Murmur's app icon, as in the design's App icon board, into the asset
// catalog: a yellow tile, a white speech bubble, a blue wave ending in a dot.
//
// swift scripts/make-icon.swift
import AppKit

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconSet = root.appending(path: "MurmurMac/Resources/Assets.xcassets/AppIcon.appiconset")

/// Draws the icon on a 1024-point canvas, y down.
func drawIcon(in context: CGContext) {
  // The tile, inset to macOS's 824-point icon grid.
  let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
  let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: CGColor(gray: 0, alpha: 0.25))
  context.addPath(tilePath)
  context.setFillColor(CGColor(red: 1, green: 0.72, blue: 0.2, alpha: 1))
  context.fillPath()
  context.restoreGState()

  context.saveGState()
  context.addPath(tilePath)
  context.clip()
  let space = CGColorSpaceCreateDeviceRGB()
  let tileGradient = CGGradient(
    colorsSpace: space,
    colors: [
      CGColor(red: 1.0, green: 0.87, blue: 0.45, alpha: 1), CGColor(red: 1.0, green: 0.66, blue: 0.12, alpha: 1),
    ] as CFArray,
    locations: [0, 1])!
  context.drawLinearGradient(tileGradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
  context.restoreGState()

  // The bubble: a rounded body, tilted a little, with a tail to the lower left.
  let bubble = CGMutablePath()
  bubble.move(to: CGPoint(x: 245, y: 440))
  bubble.addCurve(to: CGPoint(x: 540, y: 255), control1: CGPoint(x: 240, y: 300), control2: CGPoint(x: 400, y: 262))
  bubble.addCurve(to: CGPoint(x: 800, y: 430), control1: CGPoint(x: 690, y: 248), control2: CGPoint(x: 805, y: 310))
  bubble.addCurve(to: CGPoint(x: 560, y: 660), control1: CGPoint(x: 800, y: 580), control2: CGPoint(x: 690, y: 650))
  bubble.addLine(to: CGPoint(x: 420, y: 676))
  bubble.addCurve(to: CGPoint(x: 290, y: 790), control1: CGPoint(x: 380, y: 720), control2: CGPoint(x: 330, y: 770))
  bubble.addCurve(to: CGPoint(x: 318, y: 655), control1: CGPoint(x: 310, y: 740), control2: CGPoint(x: 320, y: 700))
  bubble.addCurve(to: CGPoint(x: 245, y: 440), control1: CGPoint(x: 265, y: 610), control2: CGPoint(x: 247, y: 530))
  bubble.closeSubpath()
  context.saveGState()
  context.setShadow(
    offset: CGSize(width: 0, height: 10), blur: 24, color: CGColor(red: 0.6, green: 0.35, blue: 0, alpha: 0.3))
  context.addPath(bubble)
  context.setFillColor(CGColor(red: 0.97, green: 0.98, blue: 1, alpha: 1))
  context.fillPath()
  context.restoreGState()

  // The wave, and its dot.
  let wave = CGMutablePath()
  wave.move(to: CGPoint(x: 330, y: 500))
  wave.addCurve(to: CGPoint(x: 445, y: 470), control1: CGPoint(x: 370, y: 380), control2: CGPoint(x: 420, y: 370))
  wave.addCurve(to: CGPoint(x: 545, y: 470), control1: CGPoint(x: 470, y: 580), control2: CGPoint(x: 520, y: 590))
  wave.addCurve(to: CGPoint(x: 650, y: 455), control1: CGPoint(x: 575, y: 330), control2: CGPoint(x: 620, y: 330))
  let blue = CGGradient(
    colorsSpace: space,
    colors: [
      CGColor(red: 0.25, green: 0.42, blue: 0.98, alpha: 1), CGColor(red: 0.17, green: 0.3, blue: 0.86, alpha: 1),
    ]
      as CFArray,
    locations: [0, 1])!
  let strokedWave = wave.copy(strokingWithWidth: 52, lineCap: .round, lineJoin: .round, miterLimit: 10)
  let dot = CGPath(ellipseIn: CGRect(x: 662, y: 425, width: 64, height: 64), transform: nil)
  // Filled one at a time: overlapping shapes in one clip would cancel out.
  for shape in [strokedWave, dot] {
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.drawLinearGradient(blue, start: CGPoint(x: 330, y: 360), end: CGPoint(x: 730, y: 600), options: [])
    context.restoreGState()
  }
}

func png(pixels: Int) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
  let scale = CGFloat(pixels) / 1024
  context.translateBy(x: 0, y: CGFloat(pixels))
  context.scaleBy(x: scale, y: -scale)
  drawIcon(in: context)
  return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try png(pixels: points * scale).write(to: iconSet.appending(path: name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
  }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
  .write(to: iconSet.appending(path: "Contents.json"))
try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8)
  .write(to: iconSet.deletingLastPathComponent().appending(path: "Contents.json"))
print("wrote \(iconSet.path)")
