import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import OSLog
package final class CapturePreviewRecordingSink: @unchecked Sendable, DisplayPreviewSink {
    private let destinationDirectory: URL
    private let metadata: CapturePreviewRecordingMetadata
    private let stateLock = NSLock()
    private nonisolated(unsafe) var hasWrittenFrame = false

    package init(
        destinationDirectory: URL,
        session: ScreenMonitoringSession
    ) {
        self.destinationDirectory = destinationDirectory
        self.metadata = CapturePreviewRecordingMetadata(
            sessionID: session.id.uuidString,
            displayID: session.displayID,
            displayName: session.displayName,
            resolutionText: session.resolutionText
        )
    }

    package nonisolated func submitFrame(_ sampleBuffer: CMSampleBuffer) {
        let shouldWrite: Bool = {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !hasWrittenFrame else { return false }
            hasWrittenFrame = true
            return true
        }()

        guard shouldWrite else { return }

        let sampleBufferBox = SendableSampleBufferBox(sampleBuffer)
        Task { @MainActor [destinationDirectory, metadata] in
            do {
                try FileManager.default.createDirectory(
                    at: destinationDirectory,
                    withIntermediateDirectories: true
                )

                guard let pixelBuffer = sampleBufferBox.sampleBuffer.imageBuffer else {
                    throw CapturePreviewRecordingError.missingPixelBuffer
                }

                let image = CIImage(cvPixelBuffer: pixelBuffer)
                let imageRect = image.extent.integral
                let ciContext = CIContext(options: nil)
                guard let cgImage = ciContext.createCGImage(image, from: imageRect) else {
                    throw CapturePreviewRecordingError.cgImageCreationFailed
                }

                let pngURL = destinationDirectory.appendingPathComponent("frame.png")
                try writePNG(cgImage: cgImage, to: pngURL)

                let frameMetadata = CapturePreviewRecordedFrameMetadata(
                    width: Int(imageRect.width),
                    height: Int(imageRect.height)
                )
                let metadataURL = destinationDirectory.appendingPathComponent("metadata.json")
                let payload = CapturePreviewRecordedPayload(
                    session: metadata,
                    frame: frameMetadata
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(payload)
                try data.write(to: metadataURL, options: .atomic)
            } catch {
                AppLog.capture.error("Failed to record preview sample: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private struct CapturePreviewRecordingMetadata: Codable, Sendable {
    package let sessionID: String
    package let displayID: UInt32
    package let displayName: String
    package let resolutionText: String
}

private struct CapturePreviewRecordedFrameMetadata: Codable, Sendable {
    package let width: Int
    package let height: Int
}

private struct CapturePreviewRecordedPayload: Codable, Sendable {
    package let session: CapturePreviewRecordingMetadata
    package let frame: CapturePreviewRecordedFrameMetadata
}

private enum CapturePreviewRecordingError: LocalizedError {
    case missingPixelBuffer
    case cgImageCreationFailed

    package var errorDescription: String? {
        switch self {
        case .missingPixelBuffer:
            return "Preview sample buffer did not contain an image buffer."
        case .cgImageCreationFailed:
            return "Failed to create CGImage from preview sample buffer."
        }
    }
}

private struct SendableSampleBufferBox: @unchecked Sendable {
    nonisolated(unsafe) let sampleBuffer: CMSampleBuffer

    nonisolated init(_ sampleBuffer: CMSampleBuffer) {
        self.sampleBuffer = sampleBuffer
    }
}

@MainActor
private func writePNG(cgImage: CGImage, to url: URL) throws {
    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    guard let tiffData = image.tiffRepresentation,
          let imageRep = NSBitmapImageRep(data: tiffData),
          let pngData = imageRep.representation(using: .png, properties: [:]) else {
        throw CapturePreviewRecordingError.cgImageCreationFailed
    }
    try pngData.write(to: url, options: .atomic)
}
