import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

@MainActor
package enum CapturePreviewDiagnosticsBootstrap {
    package static func makePreviewService(
        configuration: CapturePreviewDiagnosticsConfiguration
    ) throws -> CapturePreviewService {
        let session = try UITestCapturePreviewSession(configuration: configuration)
        let previewSubscription = DisplayPreviewSubscription(
            displayID: session.displayID,
            resolutionText: "\(Int(configuration.sourcePixelSize.width)) × \(Int(configuration.sourcePixelSize.height))",
            session: session,
            cancelClosure: {}
        )
        let previewSession = ScreenPreviewSession(
            id: UUID(),
            displayID: session.displayID,
            displayName: "Preview Diagnostics",
            resolutionText: previewSubscription.resolutionText,
            isVirtualDisplay: false,
            previewSubscription: previewSubscription,
            capturesCursor: false,
            state: .starting
        )
        return CapturePreviewService(initialSessions: [previewSession])
    }
}
package final class UITestCapturePreviewSession: @unchecked Sendable, DisplayCaptureSessioning {
    nonisolated let displayID: CGDirectDisplayID = 99_001
    package nonisolated let shareFrameConsumer: any DisplayShareFrameConsumer = DiagnosticsShareFrameConsumer()

    private nonisolated(unsafe) let sampleBuffer: CMSampleBuffer
    private let fanout = PreviewSampleFanout()

    package init(configuration: CapturePreviewDiagnosticsConfiguration) throws {
        self.sampleBuffer = try Self.makeSampleBuffer(configuration: configuration)
    }

    package nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        fanout.attachPreviewSink(sink)
        fanout.publishPreviewFrame(sampleBuffer)
    }

    package nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        fanout.detachPreviewSink(sink)
    }

    package nonisolated func stopSharing() {}

    package nonisolated func setDemand(_ demand: DisplayCaptureDemandSnapshot) async throws {
        _ = demand
    }

    package nonisolated func stop() async {}
}

private final class DiagnosticsShareFrameConsumer: DisplayShareFrameConsumer {
    nonisolated var hasDemand: Bool { false }
    package nonisolated func updateSourceVideoSpec(_ spec: SourceVideoSpec) {
        _ = spec
    }
    package nonisolated func updatePerformanceMode(_ mode: CapturePerformanceMode) {
        _ = mode
    }
    package nonisolated func stopSharing() {}
    package nonisolated func submitFrame(pixelBuffer: CVPixelBuffer, ptsUs: UInt64) {
        _ = pixelBuffer
        _ = ptsUs
    }
}

private extension UITestCapturePreviewSession {
    static func makeSampleBuffer(
        configuration: CapturePreviewDiagnosticsConfiguration
    ) throws -> CMSampleBuffer {
        let sourceSize = configuration.sourcePixelSize
        let width = max(1, Int(sourceSize.width.rounded()))
        let height = max(1, Int(sourceSize.height.rounded()))

        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        let creationStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard creationStatus == kCVReturnSuccess, let pixelBuffer else {
            throw CapturePreviewDiagnosticsError.pixelBufferCreationFailed(creationStatus)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw CapturePreviewDiagnosticsError.pixelBufferBaseAddressUnavailable
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw CapturePreviewDiagnosticsError.bitmapContextCreationFailed
        }

        if let replayImageURL = configuration.replayImageURL {
            try drawReplayImage(from: replayImageURL, in: context, size: CGSize(width: width, height: height))
        } else {
            drawDiagnosticPattern(in: context, size: CGSize(width: width, height: height))
        }

        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw CapturePreviewDiagnosticsError.formatDescriptionCreationFailed(formatStatus)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw CapturePreviewDiagnosticsError.sampleBufferCreationFailed(sampleStatus)
        }

        return sampleBuffer
    }

    static func drawReplayImage(
        from url: URL,
        in context: CGContext,
        size: CGSize
    ) throws {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw CapturePreviewDiagnosticsError.replayImageLoadFailed(url.path)
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
    }

    static func drawDiagnosticPattern(in context: CGContext, size: CGSize) {
        let width = size.width
        let height = size.height
        let border = max(24, min(width, height) * 0.045)
        let cornerSize = max(border * 0.9, min(width, height) * 0.08)
        let circleDiameter = min(width, height) * 0.32

        let background = CGColor(red: 0.93, green: 0.95, blue: 0.91, alpha: 1)
        context.setFillColor(background)
        context.fill(CGRect(origin: .zero, size: size))

        context.setFillColor(CGColor(red: 0.92, green: 0.32, blue: 0.27, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: border, height: height))

        context.setFillColor(CGColor(red: 0.20, green: 0.46, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: width - border, y: 0, width: border, height: height))

        context.setFillColor(CGColor(red: 0.14, green: 0.69, blue: 0.31, alpha: 1))
        context.fill(CGRect(x: 0, y: height - border, width: width, height: border))

        context.setFillColor(CGColor(red: 0.94, green: 0.78, blue: 0.17, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: border))

        drawCornerSquare(
            in: context,
            rect: CGRect(x: border * 1.2, y: height - border - cornerSize * 1.2, width: cornerSize, height: cornerSize),
            color: CGColor(red: 0.85, green: 0.20, blue: 0.68, alpha: 1)
        )
        drawCornerSquare(
            in: context,
            rect: CGRect(x: width - border - cornerSize * 1.2, y: height - border - cornerSize * 1.2, width: cornerSize, height: cornerSize),
            color: CGColor(red: 0.06, green: 0.74, blue: 0.82, alpha: 1)
        )
        drawCornerSquare(
            in: context,
            rect: CGRect(x: border * 1.2, y: border * 1.2, width: cornerSize, height: cornerSize),
            color: CGColor(red: 0.95, green: 0.48, blue: 0.18, alpha: 1)
        )
        drawCornerSquare(
            in: context,
            rect: CGRect(x: width - border - cornerSize * 1.2, y: border * 1.2, width: cornerSize, height: cornerSize),
            color: CGColor(red: 0.46, green: 0.30, blue: 0.85, alpha: 1)
        )

        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
        context.setLineWidth(max(2, border * 0.08))
        let step = max(60, min(width, height) * 0.08)
        var x: CGFloat = border
        while x < width - border {
            context.move(to: CGPoint(x: x, y: border))
            context.addLine(to: CGPoint(x: x, y: height - border))
            x += step
        }
        var y: CGFloat = border
        while y < height - border {
            context.move(to: CGPoint(x: border, y: y))
            context.addLine(to: CGPoint(x: width - border, y: y))
            y += step
        }
        context.strokePath()

        let circleRect = CGRect(
            x: (width - circleDiameter) / 2,
            y: (height - circleDiameter) / 2,
            width: circleDiameter,
            height: circleDiameter
        )
        context.setStrokeColor(CGColor(red: 0.82, green: 0.16, blue: 0.66, alpha: 1))
        context.setLineWidth(max(8, border * 0.18))
        context.strokeEllipse(in: circleRect)

        context.setStrokeColor(CGColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 0.85))
        context.setLineWidth(max(4, border * 0.09))
        context.move(to: CGPoint(x: width / 2, y: border))
        context.addLine(to: CGPoint(x: width / 2, y: height - border))
        context.move(to: CGPoint(x: border, y: height / 2))
        context.addLine(to: CGPoint(x: width - border, y: height / 2))
        context.strokePath()
    }

    static func drawCornerSquare(in context: CGContext, rect: CGRect, color: CGColor) {
        context.setFillColor(color)
        context.fill(rect)
        context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
        context.setLineWidth(max(3, rect.width * 0.05))
        context.stroke(rect)
    }
}

private final class PreviewSampleFanout: Sendable {
    private let sinks = NSLock()
    private nonisolated(unsafe) var attachedSinks: [ObjectIdentifier: any DisplayPreviewSink] = [:]

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        sinks.lock()
        attachedSinks[ObjectIdentifier(sink as AnyObject)] = sink
        sinks.unlock()
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        sinks.lock()
        attachedSinks.removeValue(forKey: ObjectIdentifier(sink as AnyObject))
        sinks.unlock()
    }

    nonisolated func publishPreviewFrame(_ sampleBuffer: CMSampleBuffer) {
        sinks.lock()
        let currentSinks = Array(attachedSinks.values)
        sinks.unlock()
        for sink in currentSinks {
            sink.submitFrame(sampleBuffer)
        }
    }
}
package enum CapturePreviewDiagnosticsError: LocalizedError {
    case pixelBufferCreationFailed(CVReturn)
    case pixelBufferBaseAddressUnavailable
    case bitmapContextCreationFailed
    case replayImageLoadFailed(String)
    case formatDescriptionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)

    package var errorDescription: String? {
        switch self {
        case .pixelBufferCreationFailed(let status):
            return "Failed to create preview diagnostics pixel buffer: \(status)"
        case .pixelBufferBaseAddressUnavailable:
            return "Failed to access preview diagnostics pixel buffer memory."
        case .bitmapContextCreationFailed:
            return "Failed to create preview diagnostics bitmap context."
        case .replayImageLoadFailed(let path):
            return "Failed to load replay image at path: \(path)"
        case .formatDescriptionCreationFailed(let status):
            return "Failed to create preview diagnostics format description: \(status)"
        case .sampleBufferCreationFailed(let status):
            return "Failed to create preview diagnostics sample buffer: \(status)"
        }
    }
}
