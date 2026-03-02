import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit
import Synchronization

// MARK: - Public Protocols & Value Types

protocol DisplayPreviewSink: AnyObject, Sendable {
    nonisolated func submitFrame(_ sampleBuffer: CMSampleBuffer)
}

nonisolated struct SendableDisplay: @unchecked Sendable {
    nonisolated(unsafe) let value: SCDisplay
    nonisolated let displayID: CGDirectDisplayID
    nonisolated let width: Int
    nonisolated let height: Int

    nonisolated init(_ value: SCDisplay) {
        self.value = value
        self.displayID = value.displayID
        self.width = value.width
        self.height = value.height
    }
}

// MARK: - Preview Subscription

final class DisplayPreviewSubscription: Sendable {
    let displayID: CGDirectDisplayID
    let resolutionText: String

    private let session: DisplayCaptureSession
    private let cancelState = Mutex<(@Sendable () -> Void)?>(nil)

    nonisolated init(
        displayID: CGDirectDisplayID,
        resolutionText: String,
        session: DisplayCaptureSession,
        cancelClosure: @escaping @Sendable () -> Void
    ) {
        self.displayID = displayID
        self.resolutionText = resolutionText
        self.session = session
        cancelState.withLock { $0 = cancelClosure }
    }

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        session.attachPreviewSink(sink)
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        session.detachPreviewSink(sink)
    }

    nonisolated func cancel() {
        let closure = cancelState.withLock { state -> (@Sendable () -> Void)? in
            let current = state
            state = nil
            return current
        }
        closure?()
    }

    deinit { cancel() }
}

// MARK: - Share Subscription

final class DisplayShareSubscription: Sendable {
    let displayID: CGDirectDisplayID
    let sessionHub: WebRTCSessionHub

    private let cancelState = Mutex<(@Sendable () -> Void)?>(nil)

    nonisolated init(
        displayID: CGDirectDisplayID,
        sessionHub: WebRTCSessionHub,
        cancelClosure: @escaping @Sendable () -> Void
    ) {
        self.displayID = displayID
        self.sessionHub = sessionHub
        cancelState.withLock { $0 = cancelClosure }
    }

    nonisolated func cancel() {
        let closure = cancelState.withLock { state -> (@Sendable () -> Void)? in
            let current = state
            state = nil
            return current
        }
        closure?()
    }

    deinit { cancel() }
}

// MARK: - Capture Registry

actor DisplayCaptureRegistry {

    struct SessionRecord {
        let session: DisplayCaptureSession
        let resolutionText: String
        var previewRefCount: Int
        var shareRefCount: Int
    }

    static let shared = DisplayCaptureRegistry()

    private var sessionsByDisplayID: [CGDirectDisplayID: SessionRecord] = [:]

    // MARK: Acquire / Release

    func acquirePreview(display: SendableDisplay) async throws -> DisplayPreviewSubscription {
        let record = try await retainSession(display: display, mode: .preview)
        let displayID = display.displayID
        return DisplayPreviewSubscription(
            displayID: displayID,
            resolutionText: record.resolutionText,
            session: record.session,
            cancelClosure: { [weak self] in
                guard let self else { return }
                Task { await self.releasePreview(displayID: displayID) }
            }
        )
    }

    func acquireShare(display: SendableDisplay) async throws -> DisplayShareSubscription {
        let record = try await retainSession(display: display, mode: .share)
        let displayID = display.displayID
        return DisplayShareSubscription(
            displayID: displayID,
            sessionHub: record.session.sessionHub,
            cancelClosure: { [weak self] in
                guard let self else { return }
                Task { await self.releaseShare(displayID: displayID) }
            }
        )
    }

    // MARK: Internal

    private enum RetainMode { case preview, share }

    private func retainSession(
        display: SendableDisplay,
        mode: RetainMode
    ) async throws -> SessionRecord {
        let displayID = display.displayID
        if var existing = sessionsByDisplayID[displayID] {
            switch mode {
            case .preview: existing.previewRefCount += 1
            case .share:   existing.shareRefCount += 1
            }
            sessionsByDisplayID[displayID] = existing
            return existing
        }

        let resolutionText = "\(display.width) × \(display.height)"
        let session = try await DisplayCaptureSession(display: display.value)
        var record = SessionRecord(
            session: session,
            resolutionText: resolutionText,
            previewRefCount: 0,
            shareRefCount: 0
        )
        switch mode {
        case .preview: record.previewRefCount = 1
        case .share:   record.shareRefCount = 1
        }
        sessionsByDisplayID[displayID] = record
        return record
    }

    private func releasePreview(displayID: CGDirectDisplayID) async {
        guard var record = sessionsByDisplayID[displayID] else { return }
        record.previewRefCount = max(0, record.previewRefCount - 1)
        sessionsByDisplayID[displayID] = record
        await removeSessionIfUnused(displayID: displayID)
    }

    private func releaseShare(displayID: CGDirectDisplayID) async {
        guard var record = sessionsByDisplayID[displayID] else { return }
        record.shareRefCount = max(0, record.shareRefCount - 1)
        if record.shareRefCount == 0 {
            record.session.stopSharing()
        }
        sessionsByDisplayID[displayID] = record
        await removeSessionIfUnused(displayID: displayID)
    }

    private func removeSessionIfUnused(displayID: CGDirectDisplayID) async {
        guard let record = sessionsByDisplayID[displayID] else { return }
        guard record.previewRefCount == 0, record.shareRefCount == 0 else { return }
        sessionsByDisplayID.removeValue(forKey: displayID)
        await record.session.stop()
    }
}

// MARK: - Stream Output Delegate

private final class DisplayStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    nonisolated(unsafe) weak var session: DisplayCaptureSession?

    nonisolated override init() {
        super.init()
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        session?.handle(sampleBuffer: sampleBuffer, type: type)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            AppErrorMapper.logFailure("Screen capture stream stopped", error: error, logger: AppLog.capture)
        }
    }
}

// MARK: - Sample Fanout

private final class DisplaySampleFanout: Sendable {
    private let sinks = Mutex<[ObjectIdentifier: any DisplayPreviewSink]>([:])

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        sinks.withLock { $0[ObjectIdentifier(sink as AnyObject)] = sink }
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        sinks.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(sink as AnyObject)) }
    }

    nonisolated func publishPreviewFrame(_ sampleBuffer: CMSampleBuffer) {
        let snapshot = sinks.withLock { Array($0.values) }
        for sink in snapshot { sink.submitFrame(sampleBuffer) }
    }
}

// MARK: - Display Capture Session

final class DisplayCaptureSession: @unchecked Sendable {
    nonisolated let displayID: CGDirectDisplayID
    nonisolated let sessionHub: WebRTCSessionHub

    nonisolated(unsafe) private let stream: SCStream
    private let output = DisplayStreamOutput()
    nonisolated private let captureQueue: DispatchQueue
    nonisolated private let fanout = DisplaySampleFanout()
    nonisolated private let metrics = Mutex(DisplayCaptureMetrics())

    // MARK: Lifecycle

    nonisolated init(display: SCDisplay) async throws {
        self.displayID = display.displayID
        self.captureQueue = DispatchQueue(
            label: "com.developerchen.voiddisplay.capture.\(display.displayID)",
            qos: .userInitiated
        )

        let config = try await Self.makeStreamConfiguration(display: display)
        let filter = try await Self.makeContentFilter(display: display)
        self.stream = SCStream(filter: filter, configuration: config, delegate: output)
        self.sessionHub = WebRTCSessionHub()

        output.session = self

        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
    }

    // MARK: Preview Sinks

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        fanout.attachPreviewSink(sink)
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        fanout.detachPreviewSink(sink)
    }

    // MARK: Sharing Control

    nonisolated func stopSharing() {
        sessionHub.stopSharing()
    }

    nonisolated func stop() async {
        stopSharing()
        try? await stream.stopCapture()
    }

    // MARK: Frame Handling

    nonisolated func handle(sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        metrics.withLock { $0.receivedFrameCount &+= 1 }

        fanout.publishPreviewFrame(sampleBuffer)

        guard sessionHub.hasDemand else { return }
        let ptsUs = Self.microseconds(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        sessionHub.submitFrame(pixelBuffer: pixelBuffer, ptsUs: ptsUs)
    }
}

// MARK: - DisplayCaptureSession Helpers

extension DisplayCaptureSession {

    nonisolated static func microseconds(from time: CMTime) -> UInt64 {
        guard time.isValid, !time.isIndefinite, time.seconds.isFinite else { return 0 }
        let scaled = CMTimeConvertScale(time, timescale: 1_000_000, method: .default)
        return scaled.value > 0 ? UInt64(scaled.value) : 0
    }

    nonisolated private static func makeStreamConfiguration(
        display: SCDisplay
    ) async throws -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let displayMode = CGDisplayCopyDisplayMode(display.displayID)

        let captureSize = preferredCaptureSize(display: display, displayMode: displayMode)
        let refreshRate = max(60.0, min(displayMode?.refreshRate ?? 60.0, 120.0))
        let timescale = CMTimeScale(max(1, Int32(refreshRate.rounded())))

        config.width = captureSize.width
        config.height = captureSize.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: timescale)
        config.queueDepth = 2
        config.showsCursor = true
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        AppLog.capture.notice(
            "Capture config display=\(display.displayID, privacy: .public) size=\(captureSize.width)x\(captureSize.height, privacy: .public)"
        )
        return config
    }

    nonisolated private static func preferredCaptureSize(
        display: SCDisplay,
        displayMode: CGDisplayMode?
    ) -> (width: Int, height: Int) {
        let modePixelWidth = displayMode.map { Int($0.pixelWidth) } ?? display.width
        let modePixelHeight = displayMode.map { Int($0.pixelHeight) } ?? display.height
        let modeLogicalWidth = displayMode.map { $0.width } ?? modePixelWidth
        let modeLogicalHeight = displayMode.map { $0.height } ?? modePixelHeight
        let backingScale = screenBackingScaleFactor(for: display.displayID)

        let scaledLogicalWidth = max(1, Int((CGFloat(modeLogicalWidth) * backingScale).rounded()))
        let scaledLogicalHeight = max(1, Int((CGFloat(modeLogicalHeight) * backingScale).rounded()))

        return (
            width: max(modePixelWidth, scaledLogicalWidth),
            height: max(modePixelHeight, scaledLogicalHeight)
        )
    }

    nonisolated private static func screenBackingScaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screen = NSScreen.screens.first(where: {
            guard let number = $0.deviceDescription[key] as? NSNumber else { return false }
            return number.uint32Value == displayID
        }) else {
            return 1.0
        }
        return max(1.0, screen.backingScaleFactor)
    }

    nonisolated private static func makeContentFilter(
        display: SCDisplay
    ) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        let excludedApps = content.applications.filter { app in
            Bundle.main.bundleIdentifier == app.bundleIdentifier
        }
        return SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )
    }
}

// MARK: - Internal Metrics

struct DisplayCaptureMetrics: Sendable {
    var receivedFrameCount: UInt64 = 0
}
