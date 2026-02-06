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

// Backward-compatible alias for old typo name used in earlier code paths.
func creatScreenCapture(
    display: SCDisplay,
    showsCursor: Bool = true,
    excludedOtherApps: [SCRunningApplication] = [],
    exceptingOtherWindows: [SCWindow] = []
) async -> ScreenCaptureSession {
    await createScreenCapture(
        display: display,
        showsCursor: showsCursor,
        excludedOtherApps: excludedOtherApps,
        exceptingOtherWindows: exceptingOtherWindows
    )
}


class StreamDelegate: NSObject, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        AppErrorMapper.logFailure("Screen capture stream stopped", error: error, logger: AppLog.capture)
    }
}

// `CVImageBuffer` is not `Sendable`; frames are immutable for our usage while flowing through the encoder actor.
private struct UncheckedImageBuffer: @unchecked Sendable {
    nonisolated(unsafe) let value: CVImageBuffer
}


@MainActor
@Observable
final class Capture: NSObject, SCStreamOutput {
    // Sample callbacks run on a dedicated queue. All app-observable state is published back on MainActor.
    nonisolated private static let captureOutputQueue = DispatchQueue(
        label: "phineas.mac.FreelyDisplay.capture.output",
        qos: .userInteractive
    )

    private actor FramePipeline {
        private var latestFrame: UncheckedImageBuffer?
        private var isEncoding = false
        private let ciContext = CIContext()
        private let jpegScale: CGFloat
        private let compressionQuality: CGFloat

        init(jpegScale: CGFloat = 0.25, compressionQuality: CGFloat = 0.65) {
            self.jpegScale = jpegScale
            self.compressionQuality = compressionQuality
        }

        func submit(
            _ frame: UncheckedImageBuffer,
            publish: @escaping @Sendable (Data?) async -> Void
        ) async {
            latestFrame = frame
            guard !isEncoding else { return }
            isEncoding = true

            while let currentFrame = latestFrame {
                latestFrame = nil
                let encoded = encodeJPEG(from: currentFrame.value)
                await publish(encoded)
            }

            isEncoding = false
        }

        func reset() {
            latestFrame = nil
        }

        private func encodeJPEG(from pixelBuffer: CVImageBuffer) -> Data? {
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
    }

    @ObservationIgnored var surface: CVImageBuffer?
    var frameNumber: UInt64 = 0
    @ObservationIgnored var jpgData: Data?
    @ObservationIgnored private var publishGeneration: UInt64 = 0
    @ObservationIgnored nonisolated private let framePipeline = FramePipeline()

    nonisolated var sampleHandlerQueue: DispatchQueue {
        Self.captureOutputQueue
    }

    func resetFrameState() {
        publishGeneration &+= 1
        surface = nil
        jpgData = nil
        frameNumber = 0
        Task {
            await framePipeline.reset()
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let pixelBufferBox = UncheckedImageBuffer(value: pixelBuffer)

        Task { [weak self, pixelBufferBox] in
            guard let self else { return }

            let generation = await MainActor.run { () -> UInt64 in
                self.surface = pixelBufferBox.value
                self.frameNumber &+= 1
                return self.publishGeneration
            }

            await self.framePipeline.submit(pixelBufferBox) { [weak self] encoded in
                guard let self else { return }
                await MainActor.run {
                    guard self.publishGeneration == generation else { return }
                    self.jpgData = encoded
                }
            }
        }
    }
}
