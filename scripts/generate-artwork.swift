#!/usr/bin/env swift
// Generates packaging/artwork/AppIcon.png (1024x1024), packaging/artwork/AppIcon.icns,
// and packaging/artwork/dmg-background{,@2x}.png directly from Sources/BurnApp/Resources/EmberSkull.png.
import AppKit
import CoreGraphics
import Foundation

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let skullURL = root.appendingPathComponent("Sources/BurnApp/Resources/EmberSkull.png")
let outDir = root.appendingPathComponent("packaging/artwork", isDirectory: true)
let fm = FileManager.default
try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let skullImage = NSImage(contentsOf: skullURL),
  let skullCG = skullImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
  fputs("FAIL: Could not load \(skullURL.path)\n", stderr)
  exit(1)
}

func renderPNG(width: Int, height: Int, to url: URL, draw: (CGContext, CGSize) -> Void) throws {
  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  guard let ctx = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else {
    throw NSError(domain: "BurnArtwork", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate bitmap context"])
  }
  ctx.interpolationQuality = .high
  ctx.setAllowsAntialiasing(true)
  ctx.setShouldAntialias(true)
  draw(ctx, CGSize(width: width, height: height))
  guard let cg = ctx.makeImage() else {
    throw NSError(domain: "BurnArtwork", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage"])
  }
  let rep = NSBitmapImageRep(cgImage: cg)
  rep.size = NSSize(width: width, height: height)
  guard let data = rep.representation(using: .png, properties: [:]) else {
    throw NSError(domain: "BurnArtwork", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
  }
  try data.write(to: url, options: .atomic)
}

func squirclePath(in rect: CGRect, radius: CGFloat) -> CGPath {
  NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).cgPath
}

// 1. macOS App Icon (1024x1024 following Apple HIG 824x824 safe tile)
let iconPNG = outDir.appendingPathComponent("AppIcon.png")
try renderPNG(width: 1024, height: 1024, to: iconPNG) { ctx, size in
  ctx.clear(CGRect(origin: .zero, size: size))
  let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
  let radius: CGFloat = 185.4
  let path = squirclePath(in: tile, radius: radius)

  // Outer drop shadow matching macOS icon elevation
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
  ctx.addPath(path)
  ctx.setFillColor(CGColor(srgbRed: 0.09, green: 0.085, blue: 0.095, alpha: 1))
  ctx.fillPath()
  ctx.restoreGState()

  // Clipped squircle fill: charcoal-obsidian gradient + subtle warm ember radial glow
  ctx.saveGState()
  ctx.addPath(path)
  ctx.clip()

  let cs = CGColorSpace(name: CGColorSpace.sRGB)!
  let bgGrad = CGGradient(
    colorsSpace: cs,
    colors: [
      CGColor(srgbRed: 0.175, green: 0.16, blue: 0.17, alpha: 1),
      CGColor(srgbRed: 0.10, green: 0.092, blue: 0.10, alpha: 1),
      CGColor(srgbRed: 0.065, green: 0.06, blue: 0.068, alpha: 1),
    ] as CFArray,
    locations: [0.0, 0.55, 1.0])!
  ctx.drawLinearGradient(
    bgGrad, start: CGPoint(x: size.width / 2, y: tile.maxY),
    end: CGPoint(x: size.width / 2, y: tile.minY), options: [])

  // Warm ember ambient glow behind the skull
  let glow = CGGradient(
    colorsSpace: cs,
    colors: [
      CGColor(srgbRed: 1.0, green: 0.36, blue: 0.11, alpha: 0.34),
      CGColor(srgbRed: 1.0, green: 0.28, blue: 0.06, alpha: 0.12),
      CGColor(srgbRed: 1.0, green: 0.25, blue: 0.05, alpha: 0.0),
    ] as CFArray,
    locations: [0.0, 0.48, 1.0])!
  let glowCenter = CGPoint(x: size.width * 0.50, y: size.height * 0.52)
  ctx.drawRadialGradient(
    glow, startCenter: glowCenter, startRadius: 0,
    endCenter: glowCenter, endRadius: 390, options: [.drawsBeforeStartLocation])

  // Draw EmberSkull centered harmoniously inside the tile
  let skullSize: CGFloat = 668
  let skullRect = CGRect(
    x: (size.width - skullSize) / 2,
    y: (size.height - skullSize) / 2 - 4,
    width: skullSize,
    height: skullSize)
  ctx.draw(skullCG, in: skullRect)

  // Subtle top bevel & inner edge rim
  ctx.addPath(squirclePath(in: tile.insetBy(dx: 1.5, dy: 1.5), radius: radius - 1.5))
  ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 0.94, blue: 0.88, alpha: 0.14))
  ctx.setLineWidth(3.0)
  ctx.strokePath()

  ctx.restoreGState()
}

// 2. Build .iconset and compile AppIcon.icns with iconutil
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

guard let masterImage = NSImage(contentsOf: iconPNG),
  let masterCG = masterImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
  fputs("FAIL: Could not reload AppIcon.png\n", stderr)
  exit(1)
}

let iconSizes: [(String, Int)] = [
  ("icon_16x16.png", 16),
  ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32),
  ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128),
  ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256),
  ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512),
  ("icon_512x512@2x.png", 1024),
]

for (filename, px) in iconSizes {
  try renderPNG(width: px, height: px, to: iconset.appendingPathComponent(filename)) { ctx, size in
    ctx.draw(masterCG, in: CGRect(origin: .zero, size: size))
  }
}

let icnsURL = outDir.appendingPathComponent("AppIcon.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
  fputs("FAIL: iconutil exited \(proc.terminationStatus)\n", stderr)
  exit(1)
}
try? fm.removeItem(at: iconset)

// 3. DMG Installer Background (660x400 @1x and 1320x800 @2x)
func drawDMG(ctx: CGContext, size: CGSize, scale: CGFloat) {
  let cs = CGColorSpace(name: CGColorSpace.sRGB)!
  let bg = CGGradient(
    colorsSpace: cs,
    colors: [
      CGColor(srgbRed: 0.115, green: 0.105, blue: 0.115, alpha: 1),
      CGColor(srgbRed: 0.075, green: 0.070, blue: 0.078, alpha: 1),
    ] as CFArray,
    locations: [0.0, 1.0])!
  ctx.drawLinearGradient(
    bg, start: CGPoint(x: size.width / 2, y: size.height),
    end: CGPoint(x: size.width / 2, y: 0), options: [])

  // Soft top ember glow
  let glow = CGGradient(
    colorsSpace: cs,
    colors: [
      CGColor(srgbRed: 1.0, green: 0.36, blue: 0.10, alpha: 0.18),
      CGColor(srgbRed: 1.0, green: 0.36, blue: 0.10, alpha: 0.0),
    ] as CFArray,
    locations: [0.0, 1.0])!
  ctx.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: size.width * 0.5, y: size.height * 0.92), startRadius: 0,
    endCenter: CGPoint(x: size.width * 0.5, y: size.height * 0.92), endRadius: 280 * scale,
    options: [.drawsBeforeStartLocation])

  // Drop zones subtle outlines at left (x=180, y=195 from bottom) and right (x=480, y=195 from bottom)
  // Note: Finder icon y=205 from top in 400pt window => y=195 from bottom in CG coordinates.
  let slotSize: CGFloat = 136 * scale
  for cx in [180 * scale, 480 * scale] {
    let rect = CGRect(
      x: cx - slotSize / 2, y: 195 * scale - slotSize / 2, width: slotSize, height: slotSize)
    let box = squirclePath(in: rect, radius: 26 * scale)
    ctx.saveGState()
    ctx.addPath(box)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0.97, blue: 0.94, alpha: 0.035))
    ctx.fillPath()
    ctx.addPath(box)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.97, blue: 0.94, alpha: 0.10))
    ctx.setLineWidth(1.2 * scale)
    ctx.strokePath()
    ctx.restoreGState()
  }

  // Crisp ember arrow between the two slots (x=285..375, y=195)
  ctx.saveGState()
  ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 0.42, blue: 0.16, alpha: 0.90))
  ctx.setLineWidth(3.0 * scale)
  ctx.setLineCap(.round)
  ctx.setLineJoin(.round)
  let y = 195 * scale
  let x1 = 286 * scale
  let x2 = 372 * scale
  ctx.move(to: CGPoint(x: x1, y: y))
  ctx.addLine(to: CGPoint(x: x2, y: y))
  ctx.move(to: CGPoint(x: x2 - 14 * scale, y: y + 12 * scale))
  ctx.addLine(to: CGPoint(x: x2, y: y))
  ctx.addLine(to: CGPoint(x: x2 - 14 * scale, y: y - 12 * scale))
  ctx.strokePath()
  ctx.restoreGState()

  // Typography via NSGraphicsContext
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

  let title = "BurnZombies"
  let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 24 * scale, weight: .bold),
    .foregroundColor: NSColor(srgbRed: 0.97, green: 0.95, blue: 0.90, alpha: 1),
  ]
  let titleSize = (title as NSString).size(withAttributes: titleAttrs)
  (title as NSString).draw(
    at: CGPoint(x: (size.width - titleSize.width) / 2, y: 336 * scale), withAttributes: titleAttrs)

  let subtitle = "Drag BurnZombies into Applications to install"
  let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13 * scale, weight: .medium),
    .foregroundColor: NSColor(srgbRed: 0.78, green: 0.75, blue: 0.72, alpha: 0.9),
  ]
  let subSize = (subtitle as NSString).size(withAttributes: subAttrs)
  (subtitle as NSString).draw(
    at: CGPoint(x: (size.width - subSize.width) / 2, y: 310 * scale), withAttributes: subAttrs)

  let footer = "You build. We burn.  ·  Free & Open Source (MIT)  ·  Apple Notarized"
  let footAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11 * scale, weight: .regular),
    .foregroundColor: NSColor(srgbRed: 0.65, green: 0.62, blue: 0.60, alpha: 0.75),
  ]
  let footSize = (footer as NSString).size(withAttributes: footAttrs)
  (footer as NSString).draw(
    at: CGPoint(x: (size.width - footSize.width) / 2, y: 26 * scale), withAttributes: footAttrs)

  NSGraphicsContext.restoreGraphicsState()
}

let dmg1x = outDir.appendingPathComponent("dmg-background.png")
let dmg2x = outDir.appendingPathComponent("dmg-background@2x.png")
try renderPNG(width: 660, height: 400, to: dmg1x) { drawDMG(ctx: $0, size: $1, scale: 1) }
try renderPNG(width: 1320, height: 800, to: dmg2x) { drawDMG(ctx: $0, size: $1, scale: 2) }

print("Generated \(iconPNG.path), \(icnsURL.path), \(dmg1x.path), \(dmg2x.path)")
