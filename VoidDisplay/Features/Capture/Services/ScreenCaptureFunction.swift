import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Observation
import OSLog
import ScreenCaptureKit
import VideoToolbox

protocol DisplayPreviewSink: AnyObject {
    func submitFrame(_ pixelBuffer: CVPixelBuffer)
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

struct DisplayCaptureMetrics: Sendable {
    var receivedFrameCount: UInt64 = 0
    var droppedPreviewFrameCount: UInt64 = 0
    var droppedEncodeFrameCount: UInt64 = 0
}

final class DisplayPreviewSubscription: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let resolutionText: String
    private let session: DisplayCaptureSession
    private var cancelClosure: (() -> Void)?

    nonisolated init(
        displayID: CGDirectDisplayID,
        resolutionText: String,
        session: DisplayCaptureSession,
        cancelClosure: @escaping () -> Void
    ) {
        self.displayID = displayID
        self.resolutionText = resolutionText
        self.session = session
        self.cancelClosure = cancelClosure
    }

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        session.attachPreviewSink(sink)
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        session.detachPreviewSink(sink)
    }

    nonisolated func cancel() {
        guard let cancelClosure else { return }
        self.cancelClosure = nil
        cancelClosure()
    }

    deinit {
        cancel()
    }
}

final class DisplayShareSubscription: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let hub: LiveSocketHub
    private var cancelClosure: (() -> Void)?

    nonisolated init(
        displayID: CGDirectDisplayID,
        hub: LiveSocketHub,
        cancelClosure: @escaping () -> Void
    ) {
        self.displayID = displayID
        self.hub = hub
        self.cancelClosure = cancelClosure
    }

    nonisolated func cancel() {
        guard let cancelClosure else { return }
        self.cancelClosure = nil
        cancelClosure()
    }

    deinit {
        cancel()
    }
}

actor DisplayCaptureRegistry {
    struct SessionRecord {
        let session: DisplayCaptureSession
        let resolutionText: String
        var previewRefCount: Int
        var shareRefCount: Int
    }

    static let shared = DisplayCaptureRegistry()

    private var sessionsByDisplayID: [CGDirectDisplayID: SessionRecord] = [:]

    func acquirePreview(display: SCDisplay) async throws -> DisplayPreviewSubscription {
        let record = try await retainSession(display: display, mode: .preview)
        let displayID = display.displayID
        return DisplayPreviewSubscription(
            displayID: displayID,
            resolutionText: record.resolutionText,
            session: record.session,
            cancelClosure: { [weak self] in
                guard let self else { return }
                Task {
                    await self.releasePreview(displayID: displayID)
                }
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
                Task {
                    await self.releaseShare(displayID: displayID)
                }
            }
        )
    }

    private enum RetainMode {
        case preview
        case share
    }

    private func retainSession(
        display: SCDisplay,
        mode: RetainMode
    ) async throws -> SessionRecord {
        let displayID = display.displayID
        if var existing = sessionsByDisplayID[displayID] {
            switch mode {
            case .preview:
                existing.previewRefCount += 1
            case .share:
                existing.shareRefCount += 1
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
        case .preview:
            record.previewRefCount = 1
        case .share:
            record.shareRefCount = 1
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

private final class DisplayStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var session: DisplayCaptureSession?

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        session?.handle(sampleBuffer: sampleBuffer, type: type)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        AppErrorMapper.logFailure("Screen capture stream stopped", error: error, logger: AppLog.capture)
    }
}

final class DisplaySampleFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var previewSinks: [ObjectIdentifier: any DisplayPreviewSink] = [:]

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        lock.lock()
        previewSinks[ObjectIdentifier(sink as AnyObject)] = sink
        lock.unlock()
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        lock.lock()
        previewSinks.removeValue(forKey: ObjectIdentifier(sink as AnyObject))
        lock.unlock()
    }

    nonisolated func publishPreviewFrame(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        let sinks = Array(previewSinks.values)
        lock.unlock()
        for sink in sinks {
            sink.submitFrame(pixelBuffer)
        }
    }
}

final class DisplayCaptureSession: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let liveSocketHub: LiveSocketHub

    private let stream: SCStream
    private let output = DisplayStreamOutput()
    private let captureQueue: DispatchQueue
    private let fanout = DisplaySampleFanout()
    private let metricsLock = NSLock()
    private var metrics = DisplayCaptureMetrics()
    private let encoderStateQueue: DispatchQueue
    private var encoder: DisplayVideoEncoder?
    private let shareResolution: (width: Int, height: Int)
    private let sourceRefreshRate: Int

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
        self.shareResolution = Self.makeShareResolution(width: Int(config.width), height: Int(config.height))
        self.sourceRefreshRate = max(60, min(Int(round(Double(config.minimumFrameInterval.timescale) / Double(config.minimumFrameInterval.value))), 120))
        self.liveSocketHub = LiveSocketHub()
        output.session = self
        self.liveSocketHub.updateDemandHandler { [weak self] hasDemand in
            self?.setEncodingDemand(hasDemand)
        }
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
    }

    deinit {
        stream.stopCapture()
    }

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        fanout.attachPreviewSink(sink)
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        fanout.detachPreviewSink(sink)
    }

    nonisolated func stopSharing() {
        liveSocketHub.broadcastControl(.stopped)
        liveSocketHub.disconnectAllClients()
        setEncodingDemand(false)
    }

    nonisolated func stop() async {
        stopSharing()
        try? await stream.stopCapture()
    }

    nonisolated func handle(sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        metricsLock.lock()
        metrics.receivedFrameCount &+= 1
        metricsLock.unlock()

        fanout.publishPreviewFrame(pixelBuffer)

        guard liveSocketHub.hasDemand else { return }
        let ptsUs = Self.microseconds(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        encoderStateQueue.async { [weak self] in
            guard let self else { return }
            self.encoder?.enqueue(pixelBuffer: pixelBuffer, ptsUs: ptsUs)
        }
    }

    nonisolated private func setEncodingDemand(_ hasDemand: Bool) {
        encoderStateQueue.async { [weak self] in
            guard let self else { return }
            if hasDemand {
                if self.encoder == nil {
                    self.encoder = DisplayVideoEncoder(
                        width: self.shareResolution.width,
                        height: self.shareResolution.height,
                        expectedFrameRate: min(self.sourceRefreshRate, 60),
                        onConfiguration: { [weak self] configuration in
                            self?.liveSocketHub.updateConfiguration(configuration)
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

    private static func microseconds(from time: CMTime) -> UInt64 {
        guard time.isValid, !time.isIndefinite, time.seconds.isFinite else { return 0 }
        let scaled = CMTimeConvertScale(time, timescale: 1_000_000, method: .default)
        return scaled.value > 0 ? UInt64(scaled.value) : 0
    }

    private static func makeShareResolution(width: Int, height: Int) -> (width: Int, height: Int) {
        let maxEdge = max(width, height)
        guard maxEdge > 2560, width > 0, height > 0 else { return (width, height) }
        let scale = 2560.0 / Double(maxEdge)
        let scaledWidth = max(2, Int((Double(width) * scale).rounded(.toNearestOrAwayFromZero)) & ~1)
        let scaledHeight = max(2, Int((Double(height) * scale).rounded(.toNearestOrAwayFromZero)) & ~1)
        return (scaledWidth, scaledHeight)
    }

    private static func makeStreamConfiguration(display: SCDisplay) async throws -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let displayMode = CGDisplayCopyDisplayMode(display.displayID)
        let width = displayMode.map { Int($0.pixelWidth) } ?? display.width
        let height = displayMode.map { Int($0.pixelHeight) } ?? display.height
        let refreshRate = max(60.0, min(displayMode?.refreshRate ?? 60.0, 120.0))

        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(refreshRate.rounded()))))
        config.queueDepth = 2
        config.showsCursor = true
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        return config
    }

    private static func makeContentFilter(display: SCDisplay) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
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

final class DisplayVideoEncoder: @unchecked Sendable {
    private struct PendingFrame {
        let pixelBuffer: CVPixelBuffer
        let ptsUs: UInt64
    }

    private let width: Int
    private let height: Int
    private let expectedFrameRate: Int
    private let onConfiguration: @Sendable (LiveVideoConfiguration) -> Void
    private let onPacket: @Sendable (EncodedVideoPacket) -> Void
    private let queue = DispatchQueue(label: "com.developerchen.voiddisplay.video-encoder", qos: .userInitiated)
    private var compressionSession: VTCompressionSession?
    private var pendingFrame: PendingFrame?
    private var encodeInFlight = false
    private var forceNextKeyframe = true
    private var currentConfiguration: LiveVideoConfiguration?

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

    nonisolated func enqueue(pixelBuffer: CVPixelBuffer, ptsUs: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingFrame = PendingFrame(pixelBuffer: pixelBuffer, ptsUs: ptsUs)
            self.processNextFrameIfPossible()
        }
    }

    nonisolated func requestKeyframe() {
        queue.async { [weak self] in
            self?.forceNextKeyframe = true
        }
    }

    nonisolated func stop() {
        queue.sync {
            pendingFrame = nil
            encodeInFlight = false
            if let compressionSession {
                VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(compressionSession)
            }
            compressionSession = nil
            currentConfiguration = nil
        }
    }

    private func processNextFrameIfPossible() {
        guard !encodeInFlight, let pendingFrame else { return }
        do {
            let session = try prepareSessionIfNeeded()
            self.pendingFrame = nil
            encodeInFlight = true

            let time = CMTime(value: CMTimeValue(pendingFrame.ptsUs), timescale: 1_000_000)
            let flags = forceNextKeyframe
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
                : nil
            forceNextKeyframe = false

            var infoFlags = VTEncodeInfoFlags()
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pendingFrame.pixelBuffer,
                presentationTimeStamp: time,
                duration: .invalid,
                frameProperties: flags,
                sourceFrameRefcon: Unmanaged.passRetained(EncodeFrameContext(
                    ptsUs: pendingFrame.ptsUs,
                    width: width,
                    height: height
                )).toOpaque(),
                infoFlagsOut: &infoFlags
            )
            if status != noErr {
                encodeInFlight = false
                processNextFrameIfPossible()
            }
        } catch {
            AppErrorMapper.logFailure("Prepare H.264 encoder", error: error, logger: AppLog.sharing)
            encodeInFlight = false
        }
    }

    private func prepareSessionIfNeeded() throws -> VTCompressionSession {
        if let compressionSession {
            return compressionSession
        }

        var session: VTCompressionSession?
        let creationStatus = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.outputCallback,
            refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            compressionSessionOut: &session
        )
        guard creationStatus == noErr, let session else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(creationStatus))
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: NSNumber(value: 1)
        )
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: NSNumber(value: expectedFrameRate)
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxFrameDelayCount,
            value: NSNumber(value: 1)
        )
        let bitrate = (width * height) <= (1920 * 1080) ? 12_000_000 : 20_000_000
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: bitrate)
        )
        VTCompressionSessionPrepareToEncodeFrames(session)

        compressionSession = session
        forceNextKeyframe = true
        return session
    }

    private final class EncodeFrameContext {
        let ptsUs: UInt64
        let width: Int
        let height: Int

        init(ptsUs: UInt64, width: Int, height: Int) {
            self.ptsUs = ptsUs
            self.width = width
            self.height = height
        }
    }

    private static let outputCallback: VTCompressionOutputCallback = { refcon, sourceFrameRefcon, status, _, sampleBuffer in
        guard let refcon else { return }
        let encoder = Unmanaged<DisplayVideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
        let context = sourceFrameRefcon.map { Unmanaged<EncodeFrameContext>.fromOpaque($0).takeRetainedValue() }
        encoder.handleEncodedSample(
            status: status,
            context: context,
            sampleBuffer: sampleBuffer
        )
    }

    private func handleEncodedSample(
        status: OSStatus,
        context: EncodeFrameContext?,
        sampleBuffer: CMSampleBuffer?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.encodeInFlight = false
                self.processNextFrameIfPossible()
            }
            guard status == noErr,
                  let context,
                  let sampleBuffer,
                  CMSampleBufferDataIsReady(sampleBuffer),
                  let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
            else {
                return
            }

            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            let isKeyframe = !notSync

            guard let payload = Self.copyBlockBufferData(dataBuffer) else { return }
            if isKeyframe, let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
               let configuration = Self.makeConfiguration(formatDescription: formatDescription, width: context.width, height: context.height) {
                currentConfiguration = configuration
                onConfiguration(configuration)
            }

            onPacket(
                EncodedVideoPacket(
                    ptsUs: context.ptsUs,
                    isKeyframe: isKeyframe,
                    width: context.width,
                    height: context.height,
                    payload: payload
                )
            )
        }
    }

    private static func copyBlockBufferData(_ blockBuffer: CMBlockBuffer) -> Data? {
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let status: OSStatus = data.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }

    private static func makeConfiguration(
        formatDescription: CMFormatDescription,
        width: Int,
        height: Int
    ) -> LiveVideoConfiguration? {
        var parameterSetPointer: UnsafePointer<UInt8>?
        var parameterSetSize = 0
        var parameterSetCount = 0
        var nalHeaderLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &parameterSetPointer,
            parameterSetSizeOut: &parameterSetSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalHeaderLength
        )
        guard status == noErr,
              let parameterSetPointer,
              parameterSetSize >= 4 else {
            return nil
        }
        let bytes = Array(UnsafeBufferPointer(start: parameterSetPointer, count: parameterSetSize))
        let codec = String(format: "avc1.%02X%02X%02X", bytes[1], bytes[2], bytes[3])
        return LiveVideoConfiguration(codec: codec, width: width, height: height, timescale: 1_000_000)
    }
}
