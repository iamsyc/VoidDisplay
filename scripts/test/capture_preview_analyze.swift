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

enum AnalyzerMode: String {
    case fit
    case native
}

enum AnalyzerError: LocalizedError {
    case missingArgument
    case invalidMode(String)
    case invalidArgument(String)
    case imageLoadFailed(String)
    case bitmapUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument:
            return "Usage: capture_preview_analyze.swift [--mode fit|native] <png-path>"
        case .invalidMode(let mode):
            return "Unsupported mode: \(mode). Expected fit or native."
        case .invalidArgument(let argument):
            return "Invalid argument: \(argument)"
        case .imageLoadFailed(let path):
            return "Failed to load image at path: \(path)"
        case .bitmapUnavailable(let path):
            return "Failed to create bitmap from image at path: \(path)"
        }
    }
}

struct AnalyzerArguments {
    let mode: AnalyzerMode
    let imagePath: String
}

struct EdgeObservation {
    let name: String
    let distance: Double
    let actual: RGBAColor
}

struct CornerObservation {
    let name: String
    let distance: Double
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
let cornerTolerance = 0.28
let circleColor = RGBAColor(red: 0.82, green: 0.16, blue: 0.66)
let circleTolerance = 0.34

func main() throws {
    let arguments = try parseArguments()

    let imagePath = URL(fileURLWithPath: arguments.imagePath).standardizedFileURL.path
    let bitmap = try loadBitmap(path: imagePath)
    let width = bitmap.pixelsWide
    let height = bitmap.pixelsHigh

    let edgeSearchRegions: [(String, CGRect)] = [
        ("left", normalizedRect(0.00, 0.10, 0.04, 0.80, imageWidth: width, imageHeight: height)),
        ("right", normalizedRect(0.96, 0.10, 0.04, 0.80, imageWidth: width, imageHeight: height)),
        ("top", normalizedRect(0.10, 0.00, 0.80, 0.04, imageWidth: width, imageHeight: height)),
        ("bottom", normalizedRect(0.10, 0.96, 0.80, 0.04, imageWidth: width, imageHeight: height))
    ]

    var edgeObservations: [EdgeObservation] = []
    for (name, rect) in edgeSearchRegions {
        let expected = expectedColors[name]!
        let (distance, actual) = nearestColorMatch(
            bitmap: bitmap,
            rect: rect,
            expected: expected
        )
        edgeObservations.append(.init(name: name, distance: distance, actual: actual))
    }

    let cornerSearchRegions: [(String, CGRect)] = [
        ("topLeftCorner", normalizedRect(0.02, 0.02, 0.22, 0.22, imageWidth: width, imageHeight: height)),
        ("topRightCorner", normalizedRect(0.78, 0.02, 0.20, 0.22, imageWidth: width, imageHeight: height)),
        ("bottomLeftCorner", normalizedRect(0.02, 0.78, 0.22, 0.20, imageWidth: width, imageHeight: height)),
        ("bottomRightCorner", normalizedRect(0.78, 0.78, 0.20, 0.20, imageWidth: width, imageHeight: height))
    ]

    var cornerObservations: [CornerObservation] = []
    for (name, rect) in cornerSearchRegions {
        let distance = nearestColorDistance(bitmap: bitmap, rect: rect, expected: expectedColors[name]!)
        cornerObservations.append(.init(name: name, distance: distance))
    }

    let circleBounds = detectMagentaCircleBounds(
        bitmap: bitmap,
        searchRect: normalizedRect(0.25, 0.25, 0.50, 0.50, imageWidth: width, imageHeight: height)
    )
    let centerColor = averageColor(bitmap: bitmap, normalizedX: 0.5, normalizedY: 0.5, radius: 4)

    var leftBlackColumns = 0
    var rightBlackColumns = 0
    if arguments.mode == .fit {
        leftBlackColumns = leadingBlackColumns(bitmap: bitmap, normalizedY: 0.5)
        rightBlackColumns = trailingBlackColumns(bitmap: bitmap, normalizedY: 0.5)
    }

    let failures = switch arguments.mode {
    case .fit:
        validateFit(
            edgeObservations: edgeObservations,
            cornerObservations: cornerObservations,
            circleBounds: circleBounds,
            leftBlackColumns: leftBlackColumns,
            rightBlackColumns: rightBlackColumns,
            imageWidth: width
        )
    case .native:
        validateNative(
            edgeObservations: edgeObservations,
            cornerObservations: cornerObservations,
            circleBounds: circleBounds,
            centerColor: centerColor
        )
    }

    if failures.isEmpty {
        print(
            "PASS mode=\(arguments.mode.rawValue) \(imagePath) size=\(width)x\(height) leftBlack=\(leftBlackColumns) rightBlack=\(rightBlackColumns)"
        )
        return
    }

    print("FAIL mode=\(arguments.mode.rawValue) \(imagePath)")
    for failure in failures {
        print(" - \(failure)")
    }
    exit(1)
}

func validateFit(
    edgeObservations: [EdgeObservation],
    cornerObservations: [CornerObservation],
    circleBounds: CGRect?,
    leftBlackColumns: Int,
    rightBlackColumns: Int,
    imageWidth: Int
) -> [String] {
    var failures: [String] = []

    for observation in edgeObservations where observation.distance > colorTolerance {
        failures.append(
            "\(observation.name) expected close to diagnostic color, actual=(\(format(observation.actual.red)), \(format(observation.actual.green)), \(format(observation.actual.blue)))"
        )
    }
    for observation in edgeObservations
    where (observation.name == "left" || observation.name == "right")
        && observation.actual.luminance < blackLuminanceThreshold {
        failures.append("\(observation.name) edge looks black, likely side letterboxing remains")
    }
    for observation in cornerObservations where observation.distance > cornerTolerance {
        failures.append("\(observation.name) marker not found in expected quadrant")
    }

    if let circleBounds {
        let ratio = Double(circleBounds.width) / Double(circleBounds.height)
        if abs(ratio - 1) > 0.12 {
            failures.append("center circle looks stretched, ratio=\(format(ratio))")
        }
    } else {
        failures.append("failed to detect center circle")
    }

    if leftBlackColumns > max(2, imageWidth / 200) {
        failures.append("left black bar width=\(leftBlackColumns)px")
    }
    if rightBlackColumns > max(2, imageWidth / 200) {
        failures.append("right black bar width=\(rightBlackColumns)px")
    }
    return failures
}

func validateNative(
    edgeObservations: [EdgeObservation],
    cornerObservations: [CornerObservation],
    circleBounds: CGRect?,
    centerColor: RGBAColor
) -> [String] {
    var failures: [String] = []

    let rightEdgeClipped = edgeObservations.first(where: { $0.name == "right" })?.distance ?? 0 > colorTolerance
    let topRightMissing = cornerObservations.first(where: { $0.name == "topRightCorner" })?.distance ?? 0 > cornerTolerance
    let bottomRightMissing = cornerObservations.first(where: { $0.name == "bottomRightCorner" })?.distance ?? 0 > cornerTolerance
    let centerCircleClipped = circleBounds == nil

    let clippingSignals = [
        rightEdgeClipped,
        topRightMissing,
        bottomRightMissing,
        centerCircleClipped
    ]
    let clippingSignalCount = clippingSignals.filter { $0 }.count
    if clippingSignalCount < 3 {
        failures.append(
            "native mode clipping signature too weak: expected at least 3 clipped signals, actual=\(clippingSignalCount)"
        )
    }

    if centerColor.luminance < blackLuminanceThreshold {
        failures.append("native mode center region is unexpectedly dark")
    }

    return failures
}

func parseArguments() throws -> AnalyzerArguments {
    let rawArguments = Array(CommandLine.arguments.dropFirst())
    guard !rawArguments.isEmpty else {
        throw AnalyzerError.missingArgument
    }

    var mode: AnalyzerMode = .fit
    var imagePath: String?
    var index = 0

    while index < rawArguments.count {
        let argument = rawArguments[index]
        if argument == "--mode" {
            guard index + 1 < rawArguments.count else {
                throw AnalyzerError.missingArgument
            }
            let rawMode = rawArguments[index + 1].lowercased()
            guard let resolvedMode = AnalyzerMode(rawValue: rawMode) else {
                throw AnalyzerError.invalidMode(rawMode)
            }
            mode = resolvedMode
            index += 2
            continue
        }

        if imagePath == nil {
            imagePath = argument
            index += 1
            continue
        }

        throw AnalyzerError.invalidArgument(argument)
    }

    guard let imagePath else {
        throw AnalyzerError.missingArgument
    }
    return AnalyzerArguments(mode: mode, imagePath: imagePath)
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

func detectMagentaCircleBounds(bitmap: NSBitmapImageRep, searchRect: CGRect) -> CGRect? {
    var minX = Int(searchRect.maxX)
    var maxX = Int(searchRect.minX)
    var minY = Int(searchRect.maxY)
    var maxY = Int(searchRect.minY)
    var found = false

    for x in Int(searchRect.minX)..<Int(searchRect.maxX) {
        for y in Int(searchRect.minY)..<Int(searchRect.maxY) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let actual = RGBAColor(
                red: Double(color.redComponent),
                green: Double(color.greenComponent),
                blue: Double(color.blueComponent)
            )
            if actual.distance(to: circleColor) <= circleTolerance {
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

func nearestColorDistance(
    bitmap: NSBitmapImageRep,
    rect: CGRect,
    expected: RGBAColor
) -> Double {
    nearestColorMatch(bitmap: bitmap, rect: rect, expected: expected).distance
}

func nearestColorMatch(
    bitmap: NSBitmapImageRep,
    rect: CGRect,
    expected: RGBAColor
) -> (distance: Double, color: RGBAColor) {
    var bestDistance = Double.greatestFiniteMagnitude
    var bestColor = RGBAColor(red: 0, green: 0, blue: 0)

    for x in Int(rect.minX)..<Int(rect.maxX) {
        for y in Int(rect.minY)..<Int(rect.maxY) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let actual = RGBAColor(
                red: Double(color.redComponent),
                green: Double(color.greenComponent),
                blue: Double(color.blueComponent)
            )
            let distance = actual.distance(to: expected)
            if distance < bestDistance {
                bestDistance = distance
                bestColor = actual
            }
        }
    }

    return (bestDistance, bestColor)
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

func normalizedRect(
    _ x: Double,
    _ y: Double,
    _ width: Double,
    _ height: Double,
    imageWidth: Int,
    imageHeight: Int
) -> CGRect {
    CGRect(
        x: Double(imageWidth) * x,
        y: Double(imageHeight) * y,
        width: Double(imageWidth) * width,
        height: Double(imageHeight) * height
    )
}

do {
    try main()
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
