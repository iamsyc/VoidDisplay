import CoreGraphics
import CoreImage
import CoreText
import CoreVideo
import Foundation
import ImageIO

struct QualityRegion: Codable, Sendable {
    let name: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct PixelError: Codable, Sendable {
    let samples: Int
    let meanAbsoluteError: Double
    let psnrDB: Double?
    let exact: Bool
    let badPixelFraction: Double
    let edgeMAE: Double

    static func measure(reference: [UInt8], decoded: [UInt8], width: Int, region: QualityRegion) throws -> Self {
        guard width > 0, reference.count == decoded.count, reference.count % (width * 4) == 0,
              region.x >= 0, region.y >= 0, region.width > 1, region.height > 0,
              region.x + region.width <= width,
              region.y + region.height <= reference.count / (width * 4) else {
            throw BenchmarkError.failed("Invalid pixel dimensions or quality region")
        }
        var squared = 0.0
        var absolute = 0.0
        var edges = 0.0
        var badPixels = 0
        for y in region.y..<(region.y + region.height) {
            for x in region.x..<(region.x + region.width) {
                let offset = (y * width + x) * 4
                var bad = false
                for channel in 0..<3 {
                    let error = Double(decoded[offset + channel]) - Double(reference[offset + channel])
                    squared += error * error
                    absolute += abs(error)
                    bad = bad || abs(error) > 16
                    if x > region.x {
                        let sourceEdge = Int(reference[offset + channel]) - Int(reference[offset + channel - 4])
                        let decodedEdge = Int(decoded[offset + channel]) - Int(decoded[offset + channel - 4])
                        edges += Double(abs(sourceEdge - decodedEdge))
                    }
                    if y > region.y {
                        let sourceEdge = Int(reference[offset + channel]) - Int(reference[offset + channel - width * 4])
                        let decodedEdge = Int(decoded[offset + channel]) - Int(decoded[offset + channel - width * 4])
                        edges += Double(abs(sourceEdge - decodedEdge))
                    }
                }
                if bad { badPixels += 1 }
            }
        }
        let pixels = region.width * region.height
        let samples = pixels * 3
        return Self(
            samples: samples, meanAbsoluteError: absolute / Double(samples),
            psnrDB: squared == 0 ? nil : 10 * log10(255 * 255 / (squared / Double(samples))),
            exact: squared == 0, badPixelFraction: Double(badPixels) / Double(pixels),
            edgeMAE: edges / Double(((region.width - 1) * region.height + (region.height - 1) * region.width) * 3)
        )
    }
}

func percentile(_ samples: [Double], _ fraction: Double) -> Double? {
    guard !samples.isEmpty else { return nil }
    let sorted = samples.sorted()
    return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
}

enum BenchmarkError: Error { case failed(String) }

/// Original CoreText/CoreGraphics chart. Coordinates and fonts are physical
/// pixels, never points scaled with resolution. No desktop capture is involved.
final class QualityFixture {
    let width: Int
    let height: Int
    let regions: [QualityRegion]
    let context = CIContext(options: [.cacheIntermediates: false])
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let panel = width / 3
        self.regions = [
            .init(name: "small-text", x: 0, y: 0, width: panel, height: height / 2),
            .init(name: "colored-text", x: panel, y: 0, width: panel, height: height / 2),
            .init(name: "one-pixel-lines", x: panel * 2, y: 0, width: width - panel * 2, height: height / 2),
            .init(name: "scroll", x: 0, y: height / 2, width: width, height: height / 2)
        ]
    }

    func image(phase: Int) throws -> CGImage {
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw BenchmarkError.failed("Cannot allocate chart")
        }
        canvas.setFillColor(CGColor(gray: 0.96, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Top-left chart coordinates match the decoded raster and saved PNG.
        canvas.translateBy(x: 0, y: CGFloat(height))
        canvas.scaleBy(x: 1, y: -1)
        let colors: [CGColor] = [
            CGColor(red: 0.8, green: 0.05, blue: 0.08, alpha: 1),
            CGColor(red: 0.05, green: 0.28, blue: 0.85, alpha: 1),
            CGColor(red: 0.04, green: 0.5, blue: 0.14, alpha: 1)
        ]
        for (index, region) in regions.enumerated() {
            canvas.saveGState()
            canvas.clip(to: CGRect(x: region.x, y: region.y, width: region.width, height: region.height))
            if index == 2 {
                canvas.setShouldAntialias(false)
                for x in stride(from: region.x + 8, to: width, by: 4) {
                    canvas.setFillColor(x % 8 == 0 ? colors[0] : CGColor(gray: 0.05, alpha: 1))
                    canvas.fill(CGRect(x: x, y: 8, width: 1, height: region.height / 2 - 8))
                }
                for y in stride(from: region.height / 2, to: region.height, by: 4) {
                    canvas.setFillColor(colors[y % 3])
                    canvas.fill(CGRect(x: region.x + 8, y: y, width: region.width - 16, height: 1))
                }
            } else {
                for row in 0..<(region.height / 24 + 2) {
                    let size = [8, 10, 12, 16][row % 4]
                    let attributes: [NSAttributedString.Key: Any] = [
                        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, CGFloat(size), nil),
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): index == 1 ? colors[row % 3] : CGColor(gray: 0.05, alpha: 1)
                    ]
                    let text = String(repeating: "VoidDisplay 0123456789 Il1 O0 RGB / +=  ", count: width / 240 + 1)
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                    canvas.saveGState()
                    canvas.translateBy(x: CGFloat(region.x + 8), y: CGFloat(region.y + row * 24 + 20 - (index == 3 ? phase * 3 : 0)))
                    canvas.scaleBy(x: 1, y: -1)
                    canvas.textPosition = .zero
                    CTLineDraw(line, canvas)
                    canvas.restoreGState()
                }
            }
            canvas.restoreGState()
        }
        // Visible change marker, independent of the scrolling region.
        canvas.setFillColor(colors[phase % colors.count])
        canvas.fill(CGRect(x: width - 48, y: height - 48, width: 32, height: 32))
        guard let image = canvas.makeImage() else { throw BenchmarkError.failed("Cannot create chart image") }
        return image
    }

    func buffer(for image: CGImage) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attributes as CFDictionary, &result) == kCVReturnSuccess, let result else {
            throw BenchmarkError.failed("Cannot allocate NV12 input")
        }
        CVBufferSetAttachment(result, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        context.render(CIImage(cgImage: image), to: result, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
        return result
    }

    func image(from buffer: CVPixelBuffer) throws -> CGImage {
        guard let image = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: width, height: height)) else {
            throw BenchmarkError.failed("Cannot read decoded image")
        }
        return image
    }

    func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { storage in
            guard let canvas = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width * 4, space: colorSpace,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw BenchmarkError.failed("Cannot read RGB pixels")
            }
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    func save(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw BenchmarkError.failed("Cannot create PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BenchmarkError.failed("Cannot write PNG") }
    }
}
