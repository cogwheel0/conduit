// Makes the macOS app icon master (1024 px PNG) from the iOS app icon.
//
//   xcrun swift desktop/packaging/macos/icon-master.swift \
//     ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon~ios-marketing.png \
//     desktop/packaging/macos/AppIcon-master.png
//
// The iOS icon is full-bleed artwork (the mark on its blue). macOS icons sit
// on Apple's grid instead: an 824 x 824 tile with continuous ("squircle")
// corners, centred on the 1024 canvas with 100 px margins, and a soft drop
// shadow below it. This script only places the artwork: it is scaled into
// the tile and clipped to its shape, never redrawn or recoloured (the
// untagged source pixels are read as sRGB, so the blue stays the same
// values). icon.sh then renders every size from the master.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else {
  FileHandle.standardError.write("usage: icon-master.swift SOURCE.png OUT.png\n".data(using: .utf8)!)
  exit(64)
}
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
  // Reinterpret, don't convert: the iOS icon carries no profile.
  let art = decoded.copy(colorSpace: srgb)
else {
  FileHandle.standardError.write("cannot read \(args[1])\n".data(using: .utf8)!)
  exit(1)
}

let canvas: CGFloat = 1024
let tileSize: CGFloat = 824
let radius: CGFloat = 185.4  // 22.5 % of the tile, as on Apple's grid
let tile = CGRect(x: (canvas - tileSize) / 2, y: (canvas - tileSize) / 2,
                  width: tileSize, height: tileSize)

/// Apple's continuous-corner rounded rectangle (the curve UIKit draws for
/// `.continuous` corners), as three cubic segments per corner.
func continuousRect(_ r: CGRect, radius: CGFloat) -> CGPath {
  let k = min(radius, min(r.width, r.height) / 2 / 1.52866483)
  let p = CGMutablePath()
  // Corner points relative to a corner, along (edge, inward) axes.
  func tr(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.maxX - x * k, y: r.maxY - y * k) }
  func br(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.maxX - x * k, y: r.minY + y * k) }
  func bl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * k) }
  func tl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.maxY - y * k) }
  typealias Corner = (CGFloat, CGFloat) -> CGPoint
  // Each corner, entered along one edge and left along the other.
  func corner(_ c: @escaping Corner, swap: Bool) {
    let pt: (CGFloat, CGFloat) -> CGPoint = swap ? { c($1, $0) } : { c($0, $1) }
    p.addCurve(to: pt(0.63149399, 0.07491100),
               control1: pt(1.08849323, 0), control2: pt(0.86840689, 0))
    p.addCurve(to: pt(0.07491176, 0.63149399),
               control1: pt(0.37282392, 0.16905899), control2: pt(0.16906013, 0.37282401))
    p.addCurve(to: pt(0, 1.52866483),
               control1: pt(0, 0.86840701), control2: pt(0, 1.08849299))
  }
  p.move(to: tl(1.52866483, 0))
  p.addLine(to: tr(1.52866483, 0))
  corner(tr, swap: false)
  p.addLine(to: br(0, 1.52866483))
  corner(br, swap: true)
  p.addLine(to: bl(1.52866483, 0))
  corner(bl, swap: false)
  p.addLine(to: tl(0, 1.52866483))
  corner(tl, swap: true)
  p.closeSubpath()
  return p
}

guard let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas),
                          bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(1) }
ctx.interpolationQuality = .high
ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

// The soft drop shadow under the tile (offset down, blurred, 30 % black).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20,
              color: CGColor(colorSpace: srgb, components: [0, 0, 0, 0.30]))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.addPath(continuousRect(tile, radius: radius))
ctx.clip()
ctx.draw(art, in: tile)
ctx.endTransparencyLayer()
ctx.restoreGState()

guard let out = ctx.makeImage(),
  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                             UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
print("wrote \(args[2]) (\(Int(canvas)) px; tile \(Int(tileSize)) px, radius \(radius))")
