#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Original vector artwork, drawn at each icon size. No exported SF Symbols or
// provider logos are embedded in the app icon.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("Config", isDirectory: true)
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-icon-" + UUID().uuidString, isDirectory: true)
let iconset = scratch.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func render(size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
                      cornerWidth: 204, cornerHeight: 204, transform: nil)
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let background = CGGradient(colorsSpace: space,
        colors: [color(0.08, 0.24, 0.29), color(0.025, 0.08, 0.15)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 250, y: 960),
                               end: CGPoint(x: 800, y: 64),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
    context.addPath(tile)
    context.setStrokeColor(color(0.72, 0.98, 0.94, 0.17))
    context.setLineWidth(3)
    context.strokePath()

    context.setStrokeColor(color(0.88, 0.98, 0.96))
    context.setLineWidth(50)
    context.strokeEllipse(in: CGRect(x: 242, y: 242, width: 540, height: 540))

    let bolt = CGMutablePath()
    bolt.move(to: CGPoint(x: 226, y: 548))
    bolt.addLine(to: CGPoint(x: 478, y: 548))
    bolt.addLine(to: CGPoint(x: 430, y: 690))
    bolt.addLine(to: CGPoint(x: 798, y: 476))
    bolt.addLine(to: CGPoint(x: 546, y: 476))
    bolt.addLine(to: CGPoint(x: 594, y: 334))
    bolt.closeSubpath()
    context.addPath(bolt)
    context.setStrokeColor(color(0.04, 0.14, 0.20))
    context.setLineWidth(22)
    context.setLineJoin(.round)
    context.strokePath()
    context.saveGState()
    context.addPath(bolt)
    context.clip()
    let accent = CGGradient(colorsSpace: space,
        colors: [color(0.38, 1, 0.76), color(0.13, 0.80, 0.99)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(accent, start: CGPoint(x: 226, y: 690),
                               end: CGPoint(x: 798, y: 334),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
    return context.makeImage()!
}

func writePNG(size: Int, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "BridgeIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create PNG destination."])
    }
    CGImageDestinationAddImage(destination, render(size: size), nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "BridgeIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not write icon PNG."])
    }
}

for points in [16, 32, 128, 256, 512] {
    try writePNG(size: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try writePNG(size: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try writePNG(size: 1024, to: output.appendingPathComponent("AppIcon.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", output.appendingPathComponent("AppIcon.icns").path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    throw NSError(domain: "BridgeIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "iconutil failed."])
}
print("Generated Config/AppIcon.png and Config/AppIcon.icns.")
