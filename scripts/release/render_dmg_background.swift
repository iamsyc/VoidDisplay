#!/usr/bin/env swift

import AppKit
import Foundation

let arguments = CommandLine.arguments

guard arguments.count == 2 else {
    fputs("Usage: render_dmg_background.swift <output-path>\n", stderr)
    exit(1)
}

let outputPath = arguments[1]

let canvasSize = NSSize(width: 660, height: 420)
let outputURL = URL(fileURLWithPath: outputPath)
let image = NSImage(size: canvasSize)
image.lockFocus()

let bounds = NSRect(origin: .zero, size: canvasSize)

func rectFromFinder(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
    NSRect(x: x, y: canvasSize.height - y - height, width: width, height: height)
}

let backgroundGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.97, green: 0.98, blue: 1.0, alpha: 1.0),
    NSColor(calibratedRed: 0.90, green: 0.94, blue: 0.99, alpha: 1.0)
])!
backgroundGradient.draw(in: bounds, angle: 270)

NSColor(calibratedRed: 0.84, green: 0.91, blue: 1.0, alpha: 0.30).setFill()
NSBezierPath(ovalIn: NSRect(x: 420, y: 220, width: 220, height: 220)).fill()

NSColor(calibratedRed: 0.72, green: 0.84, blue: 1.0, alpha: 0.18).setFill()
NSBezierPath(ovalIn: NSRect(x: -40, y: -20, width: 240, height: 240)).fill()

let panelRect = NSRect(x: 36, y: 36, width: 588, height: 348)
let panelPath = NSBezierPath(roundedRect: panelRect, xRadius: 28, yRadius: 28)
NSColor(calibratedWhite: 1.0, alpha: 0.62).setFill()
panelPath.fill()

NSColor(calibratedRed: 0.56, green: 0.68, blue: 0.92, alpha: 0.18).setStroke()
panelPath.lineWidth = 1.0
panelPath.stroke()

let labelStyle = NSMutableParagraphStyle()
labelStyle.alignment = .center

let slotSize: CGFloat = 104
let slotTopY: CGFloat = 108
let leftSlotX: CGFloat = 118
let rightSlotX: CGFloat = 438
let arrowPadding: CGFloat = 36
let arrowTipInset: CGFloat = 36

let leftGlowRect = rectFromFinder(x: leftSlotX, y: slotTopY, width: slotSize, height: slotSize)
let rightGlowRect = rectFromFinder(x: rightSlotX, y: slotTopY, width: slotSize, height: slotSize)
let leftGlowPath = NSBezierPath(roundedRect: leftGlowRect, xRadius: 32, yRadius: 32)
let rightGlowPath = NSBezierPath(roundedRect: rightGlowRect, xRadius: 32, yRadius: 32)

NSColor(calibratedRed: 0.36, green: 0.60, blue: 0.98, alpha: 0.05).setFill()
leftGlowPath.fill()

NSColor(calibratedRed: 0.36, green: 0.60, blue: 0.98, alpha: 0.12).setFill()
rightGlowPath.fill()

NSColor(calibratedRed: 0.33, green: 0.55, blue: 0.92, alpha: 0.22).setStroke()
leftGlowPath.lineWidth = 1.5
leftGlowPath.stroke()
rightGlowPath.stroke()

let arrowPath = NSBezierPath()
let arrowStartX = leftGlowRect.maxX + arrowPadding
let arrowTipX = rightGlowRect.minX - arrowTipInset
let arrowY = leftGlowRect.midY

arrowPath.move(to: NSPoint(x: arrowStartX, y: arrowY))
arrowPath.line(to: NSPoint(x: arrowTipX, y: arrowY))
arrowPath.lineWidth = 12
arrowPath.lineCapStyle = .round

NSColor(calibratedRed: 0.22, green: 0.46, blue: 0.92, alpha: 0.88).setStroke()
arrowPath.stroke()

let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: arrowTipX, y: arrowY))
arrowHead.line(to: NSPoint(x: arrowTipX - 30, y: arrowY + 26))
arrowHead.move(to: NSPoint(x: arrowTipX, y: arrowY))
arrowHead.line(to: NSPoint(x: arrowTipX - 30, y: arrowY - 26))
arrowHead.lineWidth = 12
arrowHead.lineCapStyle = .round
arrowHead.stroke()

let hintWidth: CGFloat = 148
let hintRect = NSRect(
    x: (arrowStartX + arrowTipX - hintWidth) / 2,
    y: arrowY + 18,
    width: hintWidth,
    height: 18
)

let hintAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.19, green: 0.39, blue: 0.74, alpha: 0.95),
    .paragraphStyle: labelStyle
]

"拖入 / Drag".draw(
    in: NSRect(x: hintRect.minX, y: hintRect.minY, width: hintRect.width, height: hintRect.height),
    withAttributes: hintAttributes
)
image.unlockFocus()

guard
    let tiffData = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiffData),
    let pngData = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Unable to encode DMG background image.\n", stderr)
    exit(1)
}

try pngData.write(to: outputURL, options: .atomic)
