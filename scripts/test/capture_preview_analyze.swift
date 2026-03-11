#!/usr/bin/swift

import AppKit
import Foundation

struct RGBAColor {
    let red: Double
    let green: Double
    let blue: Double

    func distance(to other: RGBAColor) -> Double {
        let dr = red - other.red
        let dg = green - other.green
        let db = blue - other.blue
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

enum AnalyzerError: LocalizedError {
    case missingArgument
    case imageLoadFailed(String)
    case bitmapUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument:
            return "Usage: capture_preview_analyze.swift <png-path>"
        case .imageLoadFailed(let path):
            return "Failed to load image at path: \(path)"
        case .bitmapUnavailable(let path):
            return "Failed to create bitmap from image at path: \(path)"
        }
    }
}

let expectedColors: [String: RGBAColor] = [
    "left": .init(red: 0.92, green: 0.32, blue: 0.27),
    "right": .init(red: 0.20, green: 0.46, blue: 0.96),
    "top": .init(red: 0.14, green: 0.69, blue: 0.31),
    "bottom": .init(red: 0.94, green: 0.78, blue: 0.17),
    "topLeftCorner": .init(red: 0.85, green: 0.20, blue: 0.68),
    "topRightCorner": .init(red: 0.06, green: 0.74, blue: 0.82),
    "bottomLeftCorner": .init(red: 0.95, green: 0.48, blue: 0.18),
    "bottomRightCorner": .init(red: 0.46, green: 0.30, blue: 0.85)
]

let colorTolerance = 0.35
let blackLuminanceThreshold = 0.08

func main() throws {
    guard CommandLine.arguments.count >= 2 else {
        throw AnalyzerError.missingArgument
    }

    let imagePath = CommandLine.arguments[1]
    let bitmap = try loadBitmap(path: imagePath)
    let width = bitmap.pixelsWide
    let height = bitmap.pixelsHigh

    let samples: [(String, Double, Double)] = [
        ("left", 0.02, 0.50),
        ("right", 0.98, 0.50),
        ("top", 0.50, 0.98),
        ("bottom", 0.50, 0.02),
        ("topLeftCorner", 0.10, 0.90),
        ("topRightCorner", 0.90, 0.90),
        ("bottomLeftCorner", 0.10, 0.10),
        ("bottomRightCorner", 0.90, 0.10)
    ]

    var failures: [String] = []
    for (name, x, y) in samples {
        let actual = averageColor(bitmap: bitmap, normalizedX: x, normalizedY: y, radius: 3)
        let expected = expectedColors[name]!
        if actual.distance(to: expected) > colorTolerance {
            failures.append("\(name) expected close to diagnostic color, actual=(\(format(actual.red)), \(format(actual.green)), \(format(actual.blue)))")
        }
        if (name == "left" || name == "right") && actual.luminance < blackLuminanceThreshold {
            failures.append("\(name) edge looks black, likely side letterboxing remains")
        }
    }

    let circleBounds = detectMagentaCircleBounds(bitmap: bitmap)
    if let circleBounds {
        let ratio = Double(circleBounds.width) / Double(circleBounds.height)
        if abs(ratio - 1) > 0.12 {
            failures.append("center circle looks stretched, ratio=\(format(ratio))")
        }
    } else {
        failures.append("failed to detect center circle")
    }

    let leftBlackColumns = leadingBlackColumns(bitmap: bitmap, normalizedY: 0.5)
    let rightBlackColumns = trailingBlackColumns(bitmap: bitmap, normalizedY: 0.5)
    if leftBlackColumns > max(2, width / 200) {
        failures.append("left black bar width=\(leftBlackColumns)px")
    }
    if rightBlackColumns > max(2, width / 200) {
        failures.append("right black bar width=\(rightBlackColumns)px")
    }

    if failures.isEmpty {
        print("PASS \(imagePath) size=\(width)x\(height) leftBlack=\(leftBlackColumns) rightBlack=\(rightBlackColumns)")
        return
    }

    print("FAIL \(imagePath)")
    for failure in failures {
        print(" - \(failure)")
    }
    exit(1)
}

func loadBitmap(path: String) throws -> NSBitmapImageRep {
    guard let image = NSImage(contentsOfFile: path) else {
        throw AnalyzerError.imageLoadFailed(path)
    }
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else {
        throw AnalyzerError.bitmapUnavailable(path)
    }
    return bitmap
}

func averageColor(
    bitmap: NSBitmapImageRep,
    normalizedX: Double,
    normalizedY: Double,
    radius: Int
) -> RGBAColor {
    let centerX = Int((Double(bitmap.pixelsWide - 1) * normalizedX).rounded())
    let centerY = Int((Double(bitmap.pixelsHigh - 1) * normalizedY).rounded())

    var red = 0.0
    var green = 0.0
    var blue = 0.0
    var samples = 0.0

    for dx in -radius...radius {
        for dy in -radius...radius {
            let x = min(max(0, centerX + dx), bitmap.pixelsWide - 1)
            let y = min(max(0, centerY + dy), bitmap.pixelsHigh - 1)
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            red += Double(color.redComponent)
            green += Double(color.greenComponent)
            blue += Double(color.blueComponent)
            samples += 1
        }
    }

    return .init(
        red: red / max(1, samples),
        green: green / max(1, samples),
        blue: blue / max(1, samples)
    )
}

func detectMagentaCircleBounds(bitmap: NSBitmapImageRep) -> CGRect? {
    var minX = bitmap.pixelsWide
    var maxX = 0
    var minY = bitmap.pixelsHigh
    var maxY = 0
    var found = false

    for x in 0..<bitmap.pixelsWide {
        for y in 0..<bitmap.pixelsHigh {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.redComponent > 0.6 && color.blueComponent > 0.45 && color.greenComponent < 0.45 {
                found = true
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
    }

    guard found else { return nil }
    return CGRect(
        x: minX,
        y: minY,
        width: maxX - minX + 1,
        height: maxY - minY + 1
    )
}

func leadingBlackColumns(bitmap: NSBitmapImageRep, normalizedY: Double) -> Int {
    let y = Int((Double(bitmap.pixelsHigh - 1) * normalizedY).rounded())
    for x in 0..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let luminance = 0.2126 * Double(color.redComponent)
            + 0.7152 * Double(color.greenComponent)
            + 0.0722 * Double(color.blueComponent)
        if luminance >= blackLuminanceThreshold {
            return x
        }
    }
    return bitmap.pixelsWide
}

func trailingBlackColumns(bitmap: NSBitmapImageRep, normalizedY: Double) -> Int {
    let y = Int((Double(bitmap.pixelsHigh - 1) * normalizedY).rounded())
    for x in stride(from: bitmap.pixelsWide - 1, through: 0, by: -1) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let luminance = 0.2126 * Double(color.redComponent)
            + 0.7152 * Double(color.greenComponent)
            + 0.0722 * Double(color.blueComponent)
        if luminance >= blackLuminanceThreshold {
            return bitmap.pixelsWide - 1 - x
        }
    }
    return bitmap.pixelsWide
}

func format(_ value: Double) -> String {
    String(format: "%.3f", value)
}

do {
    try main()
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
