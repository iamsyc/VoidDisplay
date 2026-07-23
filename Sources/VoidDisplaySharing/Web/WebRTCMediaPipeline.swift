import CoreVideo
import Foundation
import Network
import Synchronization
import VoidDisplayFoundation
import VoidDisplayObservability

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif
package final class WebRTCFrameMailbox<Frame: Sendable>: Sendable {
    package typealias Scheduler = @Sendable (@escaping @Sendable () -> Void) -> Void
    package typealias Consumer = @Sendable (Frame) -> Void

    private struct State {
        var pendingFrame: Frame?
        var isDraining = false
    }

    private let state = Mutex(State())
    private let scheduler: Scheduler
    private let consumer: Consumer

    package init(
        scheduler: @escaping Scheduler,
        consumer: @escaping Consumer
    ) {
        self.scheduler = scheduler
        self.consumer = consumer
    }

    package func submit(_ frame: Frame) {
        let shouldStartDrain = state.withLock { state -> Bool in
            state.pendingFrame = frame
            guard !state.isDraining else { return false }
            state.isDraining = true
            return true
        }
        guard shouldStartDrain else { return }
        scheduler { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        while true {
            let frame = state.withLock { state -> Frame? in
                guard let pendingFrame = state.pendingFrame else {
                    state.isDraining = false
                    return nil
                }
                state.pendingFrame = nil
                return pendingFrame
            }
            guard let frame else { return }
            consumer(frame)
        }
    }
}

#if canImport(WebRTC)
package struct WebRTCFrameTimestampSequencer: Sendable, Equatable {
    private var lastTimestampNs: Int64?

    package init() {}

    package mutating func nextTimestampNs(ptsUs: UInt64, framesPerSecond: Int) -> Int64 {
        let candidateTimestampNs: Int64
        if ptsUs > UInt64(Int64.max / 1_000) {
            candidateTimestampNs = Int64.max
        } else {
            candidateTimestampNs = Int64(ptsUs) * 1_000
        }

        guard let lastTimestampNs else {
            self.lastTimestampNs = candidateTimestampNs
            return candidateTimestampNs
        }
        guard candidateTimestampNs > lastTimestampNs else {
            let frameIntervalNs = max(1, 1_000_000_000 / Int64(max(1, framesPerSecond)))
            let repairedTimestampNs = lastTimestampNs > Int64.max - frameIntervalNs
                ? Int64.max
                : lastTimestampNs + frameIntervalNs
            self.lastTimestampNs = repairedTimestampNs
            return repairedTimestampNs
        }

        self.lastTimestampNs = candidateTimestampNs
        return candidateTimestampNs
    }
}

package nonisolated final class WebRTCMediaPipeline: Sendable {
    private let core: WebRTCMediaPipelineCore

    package var av1VideoTrack: RTCVideoTrack {
        core.av1VideoTrack
    }

    package init() {
        core = WebRTCMediaPipelineCore()
    }

    package func makePeerConnection() -> RTCPeerConnection? {
        core.makePeerConnection()
    }

    package func requiredCodecs(for codec: WebRTCVideoCodec) -> [RTCRtpCodecCapability]? {
        core.requiredCodecs(for: codec)
    }

    package func senderVideoCodecCapabilitySummary() -> String {
        core.senderVideoCodecCapabilitySummary()
    }

    package func updateActiveCodecs(_ codecs: Set<WebRTCVideoCodec>) {
        core.updateActiveCodecs(codecs)
    }

    package func updateEncodingProfile(_ profile: WebRTCStreamingProfile) {
        core.updateEncodingProfile(profile)
    }

    package func submitFrame(pixelBuffer: CVPixelBuffer, ptsUs: UInt64) {
        core.submitFrame(pixelBuffer: pixelBuffer, ptsUs: ptsUs)
    }
}

private nonisolated final class WebRTCMediaPipelineCore: @unchecked Sendable {
    private nonisolated struct PendingFrame: @unchecked Sendable {
        nonisolated(unsafe) let pixelBuffer: CVPixelBuffer
        let ptsUs: UInt64

        nonisolated init(pixelBuffer: CVPixelBuffer, ptsUs: UInt64) {
            self.pixelBuffer = pixelBuffer
            self.ptsUs = ptsUs
        }
    }

    private struct RuntimeDiagnostics {
        var submittedFrameCount = 0
        var forwardedAV1FrameCount = 0
    }

    private struct CodecOutputState: Sendable, Equatable {
        var sourceWidth: Int32
        var sourceHeight: Int32
        var outputWidth: Int32
        var outputHeight: Int32
        var framesPerSecond: Int
    }

    private static let sslInitialized: Void = {
        RTCInitializeSSL()
    }()

    private let factory: RTCPeerConnectionFactory
    nonisolated(unsafe) private let av1VideoSource: RTCVideoSource
    nonisolated(unsafe) fileprivate let av1VideoTrack: RTCVideoTrack
    nonisolated(unsafe) private let av1Capturer: RTCVideoCapturer
    private let queue = DispatchQueue(
        label: "com.developerchen.voiddisplay.webrtc.media",
        qos: .userInitiated
    )
    private let profile = Mutex(WebRTCStreamingProfile(performanceMode: .automatic))
    private let activeCodecs = Mutex<Set<WebRTCVideoCodec>>([])
    private let runtimeDiagnostics = Mutex(RuntimeDiagnostics())
    nonisolated(unsafe) private var frameMailbox: WebRTCFrameMailbox<PendingFrame>!
    nonisolated(unsafe) private var av1OutputState: CodecOutputState?
    nonisolated(unsafe) private var av1TimestampSequencer = WebRTCFrameTimestampSequencer()

    fileprivate init() {
        _ = Self.sslInitialized
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
        self.av1VideoSource = factory.videoSource()
        self.av1VideoTrack = factory.videoTrack(with: av1VideoSource, trackId: "screen-video-av1")
        self.av1Capturer = RTCVideoCapturer(delegate: av1VideoSource)
        self.frameMailbox = WebRTCFrameMailbox(
            scheduler: { [weak self] operation in
                self?.queue.async(execute: operation)
            },
            consumer: { [weak self] frame in
                self?.consume(frame)
            }
        )
    }

    fileprivate func makePeerConnection() -> RTCPeerConnection? {
        let configuration = RTCConfiguration()
        configuration.iceServers = WebRTCIceServerProvider.configuredServers()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue]
        )
        return factory.peerConnection(with: configuration, constraints: constraints, delegate: nil)
    }

    fileprivate func requiredCodecs(for codec: WebRTCVideoCodec) -> [RTCRtpCodecCapability]? {
        let capabilities = factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
        return WebRTCCodecPreference.requiredCodecs(for: codec, from: capabilities.codecs)
    }

    fileprivate func senderVideoCodecCapabilitySummary() -> String {
        let capabilities = factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
        return WebRTCCodecPreference.capabilitySummary(from: capabilities.codecs)
    }

    fileprivate func updateActiveCodecs(_ codecs: Set<WebRTCVideoCodec>) {
        activeCodecs.withLock { $0 = codecs }
        queue.async { [weak self] in
            guard let self,
                  let currentState = self.av1OutputState else {
                return
            }
            self.adaptOutputFormats(
                sourceWidth: currentState.sourceWidth,
                sourceHeight: currentState.sourceHeight,
                profile: self.profile.withLock { $0 },
                activeCodecs: codecs
            )
        }
    }

    fileprivate func updateEncodingProfile(_ profile: WebRTCStreamingProfile) {
        self.profile.withLock { $0 = profile }
        queue.async { [weak self] in
            guard let self,
                  let currentState = self.av1OutputState else {
                return
            }
            self.adaptOutputFormats(
                sourceWidth: currentState.sourceWidth,
                sourceHeight: currentState.sourceHeight,
                profile: profile,
                activeCodecs: self.activeCodecs.withLock { $0 }
            )
        }
    }

    fileprivate func submitFrame(pixelBuffer: CVPixelBuffer, ptsUs: UInt64) {
        let shouldLogFirstFrame = runtimeDiagnostics.withLock { diagnostics -> Bool in
            diagnostics.submittedFrameCount += 1
            return diagnostics.submittedFrameCount == 1
        }
        if shouldLogFirstFrame {
            AppLog.web.info(
                "WebRTC media pipeline received first source frame ptsUs=\(ptsUs, privacy: .public)."
            )
        }
        frameMailbox.submit(PendingFrame(pixelBuffer: pixelBuffer, ptsUs: ptsUs))
    }

    private func consume(_ pendingFrame: PendingFrame) {
        let pixelBuffer = pendingFrame.pixelBuffer
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        let currentProfile = profile.withLock { $0 }
        let currentActiveCodecs = activeCodecs.withLock { $0 }
        adaptOutputFormats(
            sourceWidth: width,
            sourceHeight: height,
            profile: currentProfile,
            activeCodecs: currentActiveCodecs
        )

        for codec in WebRTCVideoCodec.allCases where currentActiveCodecs.contains(codec) {
            forwardFrame(
                codec: codec,
                pixelBuffer: pixelBuffer,
                ptsUs: pendingFrame.ptsUs,
                sourceWidth: width,
                sourceHeight: height,
                profile: currentProfile
            )
        }
    }

    private func adaptOutputFormats(
        sourceWidth: Int32,
        sourceHeight: Int32,
        profile: WebRTCStreamingProfile,
        activeCodecs: Set<WebRTCVideoCodec>
    ) {
        for codec in WebRTCVideoCodec.allCases where activeCodecs.contains(codec) {
            adaptOutputFormat(for: codec, sourceWidth: sourceWidth, sourceHeight: sourceHeight, profile: profile)
        }
    }

    private func adaptOutputFormat(
        for codec: WebRTCVideoCodec,
        sourceWidth: Int32,
        sourceHeight: Int32,
        profile: WebRTCStreamingProfile
    ) {
        let outputDimensions = profile.outputDimensions(
            for: codec,
            width: sourceWidth,
            height: sourceHeight
        )
        let nextState = CodecOutputState(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            outputWidth: outputDimensions.width,
            outputHeight: outputDimensions.height,
            framesPerSecond: profile.framesPerSecond(for: codec)
        )
        switch codec {
        case .av1 where av1OutputState == nextState:
            return
        default:
            break
        }
        videoSource(for: codec).adaptOutputFormat(
            toWidth: outputDimensions.width,
            height: outputDimensions.height,
            fps: Int32(profile.framesPerSecond(for: codec))
        )
        switch codec {
        case .av1:
            av1OutputState = nextState
        }
    }

    private func forwardFrame(
        codec: WebRTCVideoCodec,
        pixelBuffer: CVPixelBuffer,
        ptsUs: UInt64,
        sourceWidth: Int32,
        sourceHeight: Int32,
        profile: WebRTCStreamingProfile
    ) {
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let framesPerSecond = profile.framesPerSecond(for: codec)
        let timestampNs = nextTimestampNs(for: codec, ptsUs: ptsUs, framesPerSecond: framesPerSecond)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: timestampNs)
        let outputDimensions = profile.outputDimensions(
            for: codec,
            width: sourceWidth,
            height: sourceHeight
        )
        if shouldLogFirstForwardedFrame(for: codec) {
            AppLog.web.info(
                "WebRTC media pipeline forwarded first \(codec.logName, privacy: .public) RTC frame input=\(sourceWidth, privacy: .public)x\(sourceHeight, privacy: .public) output=\(outputDimensions.width, privacy: .public)x\(outputDimensions.height, privacy: .public) fps=\(framesPerSecond, privacy: .public) ptsUs=\(ptsUs, privacy: .public) timestampNs=\(timestampNs, privacy: .public)."
            )
        }
        videoSource(for: codec).capturer(capturer(for: codec), didCapture: frame)
    }

    private func nextTimestampNs(
        for codec: WebRTCVideoCodec,
        ptsUs: UInt64,
        framesPerSecond: Int
    ) -> Int64 {
        switch codec {
        case .av1:
            av1TimestampSequencer.nextTimestampNs(
                ptsUs: ptsUs,
                framesPerSecond: framesPerSecond
            )
        }
    }

    private func shouldLogFirstForwardedFrame(for codec: WebRTCVideoCodec) -> Bool {
        runtimeDiagnostics.withLock { diagnostics -> Bool in
            switch codec {
            case .av1:
                diagnostics.forwardedAV1FrameCount += 1
                return diagnostics.forwardedAV1FrameCount == 1
            }
        }
    }

    private func videoSource(for codec: WebRTCVideoCodec) -> RTCVideoSource {
        switch codec {
        case .av1:
            av1VideoSource
        }
    }

    private func capturer(for codec: WebRTCVideoCodec) -> RTCVideoCapturer {
        switch codec {
        case .av1:
            av1Capturer
        }
    }
}
#endif
