#!/usr/bin/env swift

import AppKit
import Foundation

private let width: CGFloat = 660
private let height: CGFloat = 420

private func color(_ red: UInt8, _ green: UInt8, _ blue: UInt8, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat(red) / 255,
        green: CGFloat(green) / 255,
        blue: CGFloat(blue) / 255,
        alpha: alpha
    )
}

private func roundedRect(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
}

private func strokeEllipse(_ rect: NSRect, color: NSColor, width: CGFloat) {
    let path = NSBezierPath(ovalIn: rect)
    color.setStroke()
    path.lineWidth = width
    path.stroke()
}

private func drawBrandMark(in rect: NSRect) {
    roundedRect(rect, radius: 12, fill: color(23, 63, 53))

    let document = NSBezierPath()
    document.move(to: NSPoint(x: rect.minX + 12, y: rect.minY + 10))
    document.line(to: NSPoint(x: rect.minX + 12, y: rect.maxY - 10))
    document.line(to: NSPoint(x: rect.minX + 27, y: rect.maxY - 10))
    document.line(to: NSPoint(x: rect.maxX - 10, y: rect.maxY - 25))
    document.line(to: NSPoint(x: rect.maxX - 10, y: rect.minY + 10))
    document.close()
    color(255, 253, 248).setStroke()
    document.lineWidth = 2.2
    document.lineJoinStyle = .round
    document.stroke()

    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: rect.minX + 27, y: rect.maxY - 10))
    fold.line(to: NSPoint(x: rect.minX + 27, y: rect.maxY - 25))
    fold.line(to: NSPoint(x: rect.maxX - 10, y: rect.maxY - 25))
    fold.stroke()

    let check = NSBezierPath()
    check.move(to: NSPoint(x: rect.minX + 18, y: rect.minY + 20))
    check.line(to: NSPoint(x: rect.minX + 24, y: rect.minY + 14))
    check.line(to: NSPoint(x: rect.minX + 34, y: rect.minY + 27))
    color(255, 217, 201).setStroke()
    check.lineWidth = 2.8
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    check.stroke()
}

private func drawArrow() {
    let orange = color(235, 113, 77)
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 278, y: 188))
    path.curve(
        to: NSPoint(x: 382, y: 188),
        controlPoint1: NSPoint(x: 310, y: 206),
        controlPoint2: NSPoint(x: 350, y: 206)
    )
    orange.setStroke()
    path.lineWidth = 7
    path.lineCapStyle = .round
    path.stroke()

    let arrowhead = NSBezierPath()
    arrowhead.move(to: NSPoint(x: 368, y: 204))
    arrowhead.line(to: NSPoint(x: 389, y: 188))
    arrowhead.line(to: NSPoint(x: 368, y: 172))
    arrowhead.lineCapStyle = .round
    arrowhead.lineJoinStyle = .round
    arrowhead.lineWidth = 7
    arrowhead.stroke()
}

private func drawText(_ text: String, at point: NSPoint, font: NSFont, color textColor: NSColor) {
    (text as NSString).draw(
        at: point,
        withAttributes: [
            .font: font,
            .foregroundColor: textColor,
        ]
    )
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: render-dmg-background.swift OUTPUT.png\n".utf8))
    exit(64)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width),
    pixelsHigh: Int(height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("Unable to allocate DMG background bitmap\n".utf8))
    exit(1)
}
bitmap.size = NSSize(width: width, height: height)
guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
    FileHandle.standardError.write(Data("Unable to create DMG background context\n".utf8))
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext

color(246, 241, 229).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

color(205, 234, 221, alpha: 0.72).setFill()
NSBezierPath(ovalIn: NSRect(x: 183, y: 42, width: 294, height: 294)).fill()
strokeEllipse(NSRect(x: 126, y: 58, width: 410, height: 230), color: color(36, 88, 72, alpha: 0.17), width: 1.2)
strokeEllipse(NSRect(x: 225, y: 22, width: 220, height: 320), color: color(36, 88, 72, alpha: 0.13), width: 1.2)

roundedRect(NSRect(x: 32, y: 28, width: 596, height: 364), radius: 24, fill: color(255, 253, 248, alpha: 0.66))

let brandRect = NSRect(x: 50, y: 335, width: 48, height: 48)
drawBrandMark(in: brandRect)
drawText("File Flip", at: NSPoint(x: 112, y: 344), font: NSFont.systemFont(ofSize: 22, weight: .bold), color: color(25, 53, 46))

drawText("Install File Flip", at: NSPoint(x: 50, y: 288), font: NSFont(name: "Georgia", size: 34) ?? NSFont.systemFont(ofSize: 34), color: color(25, 53, 46))
drawText("Drag FileFlip.app into Applications", at: NSPoint(x: 51, y: 260), font: NSFont.systemFont(ofSize: 15, weight: .medium), color: color(86, 112, 105))

drawArrow()

roundedRect(NSRect(x: 177, y: 48, width: 306, height: 34), radius: 17, fill: color(23, 63, 53, alpha: 0.94))
drawText("macOS 15+   •   Apple Silicon   •   Works offline", at: NSPoint(x: 203, y: 57), font: NSFont.systemFont(ofSize: 11, weight: .semibold), color: color(255, 253, 248))

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("Unable to render DMG background\n".utf8))
    exit(1)
}

try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: output, options: .atomic)
