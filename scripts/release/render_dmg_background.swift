#!/usr/bin/env swift

import AppKit
import Foundation

let arguments = CommandLine.arguments

guard arguments.count == 2 else {
    fputs("Usage: render_dmg_background.swift <output-path>\n", stderr)
    exit(1)
}

let outputPath = arguments[1]

let canvasSize = NSSize(width: 660, height: 460)
let outputURL = URL(fileURLWithPath: outputPath)
let image = NSImage(size: canvasSize)
image.lockFocus()

let bounds = NSRect(origin: .zero, size: canvasSize)

func rectFromFinder(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
    NSRect(x: x, y: canvasSize.height - y - height, width: width, height: height)
}

func pointFromFinder(x: CGFloat, y: CGFloat) -> NSPoint {
    NSPoint(x: x, y: canvasSize.height - y)
}

let backgroundGradient = NSGradient(colors: [
    NSColor(calibratedWhite: 0.95, alpha: 1.0),
    NSColor(calibratedWhite: 0.92, alpha: 1.0)
])!
backgroundGradient.draw(in: bounds, angle: 270)

let iconCenterY: CGFloat = 160
let leftIconCenterX: CGFloat = 170
let rightIconCenterX: CGFloat = 490

let slotFrameSize: CGFloat = 150
let slotFrameCornerRadius: CGFloat = 24
let leftFrameRect = rectFromFinder(
    x: leftIconCenterX - (slotFrameSize / 2),
    y: iconCenterY - (slotFrameSize / 2),
    width: slotFrameSize,
    height: slotFrameSize
)
let rightFrameRect = rectFromFinder(
    x: rightIconCenterX - (slotFrameSize / 2),
    y: iconCenterY - (slotFrameSize / 2),
    width: slotFrameSize,
    height: slotFrameSize
)

for frameRect in [leftFrameRect, rightFrameRect] {
    let framePath = NSBezierPath(roundedRect: frameRect, xRadius: slotFrameCornerRadius, yRadius: slotFrameCornerRadius)
    NSColor(calibratedWhite: 1.0, alpha: 0.12).setFill()
    framePath.fill()
    framePath.lineWidth = 2.0
    framePath.setLineDash([8, 6], count: 2, phase: 0)
    NSColor(calibratedWhite: 0.75, alpha: 0.88).setStroke()
    framePath.stroke()
}

let arrowPath = NSBezierPath()
let arrowPadding: CGFloat = 50
let arrowTipInset: CGFloat = 50
let arrowStartX = leftFrameRect.maxX + arrowPadding
let arrowTipX = rightFrameRect.minX - arrowTipInset
let arrowY = pointFromFinder(x: 0, y: iconCenterY).y

arrowPath.move(to: NSPoint(x: arrowStartX, y: arrowY))
arrowPath.line(to: NSPoint(x: arrowTipX, y: arrowY))
arrowPath.lineWidth = 4.5
arrowPath.lineCapStyle = .round

NSColor(calibratedWhite: 0.62, alpha: 0.92).setStroke()
arrowPath.stroke()

let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: arrowTipX, y: arrowY))
arrowHead.line(to: NSPoint(x: arrowTipX - 11, y: arrowY + 9))
arrowHead.move(to: NSPoint(x: arrowTipX, y: arrowY))
arrowHead.line(to: NSPoint(x: arrowTipX - 11, y: arrowY - 9))
arrowHead.lineWidth = 4.5
arrowHead.lineCapStyle = .round
arrowHead.stroke()
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
