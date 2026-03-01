import CoreGraphics
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit
import Synchronization
import VideoToolbox

// MARK: - Public Protocols & Value Types

protocol DisplayPreviewSink: AnyObject {
    nonisolated func submitFrame(_ sampleBuffer: CMSampleBuffer)
}

struct LiveVideoConfiguration: Equatable, Sendable {
    let codec: String
    let width: Int
    let height: Int
    let timescale: Int
}

struct EncodedVideoPacket: Sendable {
    let ptsUs: UInt64
    let isKeyframe: Bool
    let width: Int
    let height: Int
    let payload: Data
}

// MARK: - Sendable Wrappers

private struct SendablePixelBuffer: @unchecked Sendable {
    nonisolated(unsafe) let pixelBuffer: CVPixelBuffer
}

private struct SendableSampleBuffer: @unchecked Sendable {
    nonisolated(unsafe) let sampleBuffer: CMSampleBuffer
    nonisolated init(_ sampleBuffer: CMSampleBuffer) { self.sampleBuffer = sampleBuffer }
}

// MARK: - Preview Subscription

final class DisplayPreviewSubscription: Sendable {
    let displayID: CGDirectDisplayID
    let resolutionText: String

    private let session: DisplayCaptureSession
    private let cancelState = Mutex<(() -> Void)?>(nil)

    nonisolated init(
        displayID: CGDirectDisplayID,
        resolutionText: String,
        session: DisplayCaptureSession,
        cancelClosure: @escaping () -> Void
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
        let closure = cancelState.withLock { state -> (() -> Void)? in
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
    let hub: LiveSocketHub

    private let cancelState = Mutex<(() -> Void)?>(nil)

    nonisolated init(
        displayID: CGDirectDisplayID,
        hub: LiveSocketHub,
        cancelClosure: @escaping () -> Void
    ) {
        self.displayID = displayID
        self.hub = hub
        cancelState.withLock { $0 = cancelClosure }
    }

    nonisolated func cancel() {
        let closure = cancelState.withLock { state -> (() -> Void)? in
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

    func acquirePreview(display: SCDisplay) async throws -> DisplayPreviewSubscription {
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

    func acquireShare(display: SCDisplay) async throws -> DisplayShareSubscription {
        let record = try await retainSession(display: display, mode: .share)
        let displayID = display.displayID
        return DisplayShareSubscription(
            displayID: displayID,
            hub: record.session.liveSocketHub,
            cancelClosure: { [weak self] in
                guard let self else { return }
                Task { await self.releaseShare(displayID: displayID) }
            }
        )
    }

    // MARK: Internal

    private enum RetainMode { case preview, share }

    private func retainSession(
        display: SCDisplay,
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
        let session = try await DisplayCaptureSession(display: display)
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
    nonisolated let liveSocketHub: LiveSocketHub

    nonisolated(unsafe) private let stream: SCStream
    nonisolated private let output = DisplayStreamOutput()
    nonisolated private let captureQueue: DispatchQueue
    nonisolated private let fanout = DisplaySampleFanout()
    nonisolated private let metrics = Mutex(DisplayCaptureMetrics())
    nonisolated private let encoderStateQueue: DispatchQueue
    nonisolated(unsafe) private var encoder: DisplayVideoEncoder?
    nonisolated private let shareResolution: (width: Int, height: Int)
    nonisolated private let sourceRefreshRate: Int

    // MARK: Lifecycle

    nonisolated init(display: SCDisplay) async throws {
        self.displayID = display.displayID
        self.captureQueue = DispatchQueue(
            label: "com.developerchen.voiddisplay.capture.\(display.displayID)",
            qos: .userInitiated
        )
        self.encoderStateQueue = DispatchQueue(
            label: "com.developerchen.voiddisplay.capture.encoder.\(display.displayID)",
            qos: .userInitiated
        )

        let config = try await Self.makeStreamConfiguration(display: display)
        let filter = try await Self.makeContentFilter(display: display)
        self.stream = SCStream(filter: filter, configuration: config, delegate: output)
        self.shareResolution = Self.makeShareResolution(
            width: Int(config.width), height: Int(config.height)
        )
        let interval = config.minimumFrameInterval
        let fps = Int(round(Double(interval.timescale) / Double(interval.value)))
        self.sourceRefreshRate = max(60, min(fps, 120))
        self.liveSocketHub = LiveSocketHub()

        output.session = self
        liveSocketHub.updateDemandHandler { [weak self] hasDemand in
            self?.setEncodingDemand(hasDemand)
        }

        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
    }

    deinit {
        stream.stopCapture()
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
        liveSocketHub.broadcastControl(.stopped)
        liveSocketHub.disconnectAllClients()
        setEncodingDemand(false)
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

        guard liveSocketHub.hasDemand else { return }
        let ptsUs = Self.microseconds(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let box = SendablePixelBuffer(pixelBuffer: pixelBuffer)
        encoderStateQueue.async { [weak self] in
            self?.encoder?.enqueue(pixelBuffer: box.pixelBuffer, ptsUs: ptsUs)
        }
    }

    // MARK: Encoder Demand

    nonisolated private func setEncodingDemand(_ hasDemand: Bool) {
        encoderStateQueue.async { [weak self] in
            guard let self else { return }
            if hasDemand {
                if self.encoder == nil {
                    self.encoder = DisplayVideoEncoder(
                        width: self.shareResolution.width,
                        height: self.shareResolution.height,
                        expectedFrameRate: min(self.sourceRefreshRate, 60),
                        onConfiguration: { [weak self] config in
                            self?.liveSocketHub.updateConfiguration(config)
                        },
                        onPacket: { [weak self] packet in
                            self?.liveSocketHub.broadcast(packet: packet)
                        }
                    )
                }
                self.encoder?.requestKeyframe()
            } else {
                self.encoder?.stop()
                self.encoder = nil
            }
        }
    }
}

// MARK: - DisplayCaptureSession Helpers

extension DisplayCaptureSession {

    nonisolated static func microseconds(from time: CMTime) -> UInt64 {
        guard time.isValid, !time.isIndefinite, time.seconds.isFinite else { return 0 }
        let scaled = CMTimeConvertScale(time, timescale: 1_000_000, method: .default)
        return scaled.value > 0 ? UInt64(scaled.value) : 0
    }

    nonisolated static func makeShareResolution(
        width: Int, height: Int
    ) -> (width: Int, height: Int) {
        let maxEdge = max(width, height)
        guard maxEdge > 2560, width > 0, height > 0 else { return (width, height) }
        let scale = 2560.0 / Double(maxEdge)
        let w = max(2, Int((Double(width)  * scale).rounded(.toNearestOrAwayFromZero)) & ~1)
        let h = max(2, Int((Double(height) * scale).rounded(.toNearestOrAwayFromZero)) & ~1)
        return (w, h)
    }

    private static func makeStreamConfiguration(
        display: SCDisplay
    ) async throws -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let displayMode = CGDisplayCopyDisplayMode(display.displayID)

        let width = displayMode.map { Int($0.pixelWidth) } ?? display.width
        let height = displayMode.map { Int($0.pixelHeight) } ?? display.height
        let refreshRate = max(60.0, min(displayMode?.refreshRate ?? 60.0, 120.0))
        let timescale = CMTimeScale(max(1, Int32(refreshRate.rounded())))

        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: timescale)
        config.queueDepth = 2
        config.showsCursor = true
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        return config
    }

    private static func makeContentFilter(
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

// MARK: - Display Video Encoder (H.264 / VideoToolbox)

final class DisplayVideoEncoder: @unchecked Sendable {

    private struct PendingFrame {
        let pixelBuffer: SendablePixelBuffer
        let ptsUs: UInt64
    }

    private let width: Int
    private let height: Int
    private let expectedFrameRate: Int
    private let onConfiguration: @Sendable (LiveVideoConfiguration) -> Void
    private let onPacket: @Sendable (EncodedVideoPacket) -> Void

    private let queue = DispatchQueue(
        label: "com.developerchen.voiddisplay.video-encoder",
        qos: .userInitiated
    )
    nonisolated(unsafe) private var compressionSession: VTCompressionSession?
    nonisolated(unsafe) private var pendingFrame: PendingFrame?
    nonisolated(unsafe) private var encodeInFlight = false
    nonisolated(unsafe) private var forceNextKeyframe = true
    nonisolated(unsafe) private var currentConfiguration: LiveVideoConfiguration?

    // MARK: Lifecycle

    nonisolated init(
        width: Int,
        height: Int,
        expectedFrameRate: Int,
        onConfiguration: @escaping @Sendable (LiveVideoConfiguration) -> Void,
        onPacket: @escaping @Sendable (EncodedVideoPacket) -> Void
    ) {
        self.width = width
        self.height = height
        self.expectedFrameRate = expectedFrameRate
        self.onConfiguration = onConfiguration
        self.onPacket = onPacket
    }

    // MARK: Public API

    nonisolated func enqueue(pixelBuffer: CVPixelBuffer, ptsUs: UInt64) {
        let frame = PendingFrame(
            pixelBuffer: SendablePixelBuffer(pixelBuffer: pixelBuffer),
            ptsUs: ptsUs
        )
        queue.async { [weak self, frame] in
            guard let self else { return }
            self.pendingFrame = frame
            self.processNextFrameIfPossible()
        }
    }

    nonisolated func requestKeyframe() {
        queue.async { [weak self] in self?.forceNextKeyframe = true }
    }

    nonisolated func stop() {
        queue.sync {
            pendingFrame = nil
            encodeInFlight = false
            if let compressionSession {
                VTCompressionSessionCompleteFrames(
                    compressionSession, untilPresentationTimeStamp: .invalid
                )
                VTCompressionSessionInvalidate(compressionSession)
            }
            compressionSession = nil
            currentConfiguration = nil
        }
    }

    // MARK: Encode Pipeline

    nonisolated private func processNextFrameIfPossible() {
        guard !encodeInFlight, let pendingFrame else { return }
        do {
            let session = try prepareSessionIfNeeded()
            self.pendingFrame = nil
            encodeInFlight = true

            let time = CMTime(value: CMTimeValue(pendingFrame.ptsUs), timescale: 1_000_000)
            let flags: CFDictionary? = forceNextKeyframe
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
                : nil
            forceNextKeyframe = false

            let ptsUs = pendingFrame.ptsUs
            let w = width, h = height

            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pendingFrame.pixelBuffer.pixelBuffer,
                presentationTimeStamp: time,
                duration: .invalid,
                frameProperties: flags,
                infoFlagsOut: nil
            ) { [weak self] status, _, sampleBuffer in
                self?.handleEncodedOutput(
                    status: status, ptsUs: ptsUs,
                    width: w, height: h,
                    sampleBuffer: sampleBuffer
                )
            }
            if status != noErr {
                encodeInFlight = false
                processNextFrameIfPossible()
            }
        } catch {
            Task { @MainActor in
                AppErrorMapper.logFailure(
                    "Prepare H.264 encoder", error: error, logger: AppLog.sharing
                )
            }
            encodeInFlight = false
        }
    }

    // MARK: Session Setup

    nonisolated private func prepareSessionIfNeeded() throws -> VTCompressionSession {
        if let compressionSession { return compressionSession }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: NSNumber(value: 1))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: expectedFrameRate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount,
                             value: NSNumber(value: 1))

        let bitrate = (width * height) <= (1920 * 1080) ? 12_000_000 : 20_000_000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrate))

        VTCompressionSessionPrepareToEncodeFrames(session)
        compressionSession = session
        forceNextKeyframe = true
        return session
    }

    // MARK: Output Handling

    nonisolated private func handleEncodedOutput(
        status: OSStatus,
        ptsUs: UInt64,
        width: Int,
        height: Int,
        sampleBuffer: CMSampleBuffer?
    ) {
        let box = sampleBuffer.map(SendableSampleBuffer.init)
        queue.async { [weak self, box] in
            guard let self else { return }
            defer {
                self.encodeInFlight = false
                self.processNextFrameIfPossible()
            }
            guard status == noErr,
                  let sampleBuffer = box?.sampleBuffer,
                  CMSampleBufferDataIsReady(sampleBuffer),
                  let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
            else { return }

            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false
            ) as? [[CFString: Any]]
            let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

            guard let payload = Self.copyBlockBufferData(dataBuffer) else { return }

            if isKeyframe,
               let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
               let config = Self.makeConfiguration(
                   formatDescription: desc, width: width, height: height
               ) {
                self.currentConfiguration = config
                self.onConfiguration(config)
            }

            self.onPacket(EncodedVideoPacket(
                ptsUs: ptsUs, isKeyframe: isKeyframe,
                width: width, height: height, payload: payload
            ))
        }
    }

    // MARK: Utilities

    nonisolated private static func copyBlockBufferData(_ blockBuffer: CMBlockBuffer) -> Data? {
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let status: OSStatus = data.withUnsafeMutableBytes { buf -> OSStatus in
            guard let base = buf.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                blockBuffer, atOffset: 0, dataLength: length, destination: base
            )
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }

    nonisolated private static func makeConfiguration(
        formatDescription: CMFormatDescription,
        width: Int,
        height: Int
    ) -> LiveVideoConfiguration? {
        var ptr: UnsafePointer<UInt8>?
        var size = 0
        var count = 0
        var nalLen: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription, parameterSetIndex: 0,
            parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen
        )
        guard status == noErr, let ptr, size >= 4 else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: ptr, count: size))
        let codec = String(format: "avc1.%02X%02X%02X", bytes[1], bytes[2], bytes[3])
        return LiveVideoConfiguration(
            codec: codec, width: width, height: height, timescale: 1_000_000
        )
    }
}

// MARK: - Internal Metrics

struct DisplayCaptureMetrics: Sendable {
    var receivedFrameCount: UInt64 = 0
}
