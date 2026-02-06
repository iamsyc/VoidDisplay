//
//  ScreenCapture.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/4.
//

import Foundation
import ScreenCaptureKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Observation
import OSLog

struct ScreenCaptureSession {
    let stream: SCStream
    let delegate: StreamDelegate
}

func createScreenCapture(
    display: SCDisplay,
    showsCursor: Bool = true,
    excludedOtherApps: [SCRunningApplication] = [],
    exceptingOtherWindows: [SCWindow] = []
) async -> ScreenCaptureSession {
    let streamConfig = SCStreamConfiguration()

    streamConfig.width = display.width * 4
    streamConfig.height = display.height * 4

    streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(60))

    streamConfig.showsCursor = showsCursor

    streamConfig.capturesAudio = false

    let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

    var excludedApps = content?.applications.filter { app in
        Bundle.main.bundleIdentifier == app.bundleIdentifier
    } ?? []
    excludedApps.append(contentsOf: excludedOtherApps)

    let filter = SCContentFilter(display: display,
                                excludingApplications: excludedApps,
                                exceptingWindows: exceptingOtherWindows)
    let delegate = StreamDelegate()
    let stream = SCStream(filter: filter, configuration: streamConfig, delegate: delegate)

    return ScreenCaptureSession(stream: stream, delegate: delegate)
}


class StreamDelegate: NSObject, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        AppErrorMapper.logFailure("Screen capture stream stopped", error: error, logger: AppLog.capture)
    }
}

private struct UncheckedImageBuffer: @unchecked Sendable {
    let value: CVImageBuffer
}

private struct UncheckedSampleBuffer: @unchecked Sendable {
    nonisolated(unsafe) let value: CMSampleBuffer
}

private struct PendingFrame: @unchecked Sendable {
    let sampleBuffer: UncheckedSampleBuffer
    let pixelBuffer: UncheckedImageBuffer
}

@MainActor
@Observable
final class Capture: NSObject, SCStreamOutput {
    // Keep callbacks on main actor and offload JPEG encoding to a serial background queue.
    @ObservationIgnored nonisolated private let encodingQueue = DispatchQueue(
        label: "phineas.mac.FreelyDisplay.capture.jpeg",
        qos: .userInitiated
    )
    @ObservationIgnored nonisolated private let ciContext = CIContext()
    @ObservationIgnored nonisolated private let jpegScale: CGFloat = 0.25
    @ObservationIgnored nonisolated private let compressionQuality: CGFloat = 0.65

    @ObservationIgnored var surface: CVImageBuffer?
    var frameNumber: UInt64 = 0
    // Safe because writes happen on MainActor and reads are also on MainActor (via assumeIsolated).
    @ObservationIgnored var jpgData: Data?
    @ObservationIgnored private var latestPendingFrame: PendingFrame?
    @ObservationIgnored private var isEncodingLoopRunning = false
    @ObservationIgnored private var encodingGeneration: UInt64 = 0

    nonisolated var sampleHandlerQueue: DispatchQueue {
        .main
    }

    nonisolated private func encodeJPEG(from pixelBuffer: CVImageBuffer) -> Data? {
        autoreleasepool {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let outputImage = ciImage.transformed(by: CGAffineTransform(scaleX: jpegScale, y: jpegScale))
            guard let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) else { return nil }

            let mutableData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                mutableData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else { return nil }

            let options = [kCGImageDestinationLossyCompressionQuality as String: compressionQuality] as CFDictionary
            CGImageDestinationAddImage(destination, cgImage, options)
            return CGImageDestinationFinalize(destination) ? (mutableData as Data) : nil
        }
    }

    func resetFrameState() {
        encodingGeneration &+= 1
        surface = nil
        jpgData = nil
        frameNumber = 0
        latestPendingFrame = nil
        isEncodingLoopRunning = false
    }

    @MainActor func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        
        // Wrap the sample buffer to extend the pixel buffer's lifetime beyond this callback.
        // CMSampleBuffer implicitly retains its underlying CVImageBuffer.
        // ScreenCaptureKit may recycle the buffer after this method returns.
        let retainedSampleBuffer = UncheckedSampleBuffer(value: sampleBuffer)
        let pixelBufferBox = UncheckedImageBuffer(value: pixelBuffer)

        surface = pixelBuffer
        frameNumber &+= 1
        latestPendingFrame = PendingFrame(
            sampleBuffer: retainedSampleBuffer,
            pixelBuffer: pixelBufferBox
        )
        scheduleEncodingLoopIfNeeded()
    }

    private func scheduleEncodingLoopIfNeeded() {
        guard !isEncodingLoopRunning else { return }
        isEncodingLoopRunning = true
        let generation = encodingGeneration

        Task { [weak self] in
            await self?.runEncodingLoop(generation: generation)
        }
    }

    private func runEncodingLoop(generation: UInt64) async {
        while true {
            guard generation == encodingGeneration else { return }
            guard let frame = latestPendingFrame else {
                isEncodingLoopRunning = false
                return
            }

            // Always keep only the latest pending frame to minimize live-stream latency.
            latestPendingFrame = nil
            let encoded = await encodeJPEGAsync(from: frame)
            guard generation == encodingGeneration else { return }
            jpgData = encoded
        }
    }

    nonisolated private func encodeJPEGAsync(from frame: PendingFrame) async -> Data? {
        await withCheckedContinuation { continuation in
            encodingQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                // Keep the sample buffer alive while encoding its pixel buffer.
                _ = frame.sampleBuffer
                continuation.resume(returning: self.encodeJPEG(from: frame.pixelBuffer.value))
            }
        }
    }
}
