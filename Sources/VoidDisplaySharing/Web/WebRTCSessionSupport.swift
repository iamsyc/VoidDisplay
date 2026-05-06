import CoreVideo
import Foundation
import Network
import Synchronization
import VoidDisplayFoundation
import VoidDisplayObservability

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

package protocol SignalSocketConnection: AnyObject {
    nonisolated func sendSocketFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void)
    nonisolated func cancelSocket()
}

extension NWConnection: SignalSocketConnection {
    package nonisolated func sendSocketFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void) {
        send(content: content, completion: .contentProcessed(completion))
    }

    package nonisolated func cancelSocket() {
        cancel()
    }
}

package enum SignalSessionClientAddResult: Sendable, Equatable {
    case accepted(clientID: String)
    case rejected(reason: String)
}

package struct WebRTCStreamingProfile: Sendable, Equatable {
    package let framesPerSecond: Int
    package let minBitrateBps: Int
    package let maxBitrateBps: Int
    package let pixelBudgetPerSecond: Int64?

    package init(
        framesPerSecond: Int,
        minBitrateBps: Int,
        maxBitrateBps: Int,
        pixelBudgetPerSecond: Int64?
    ) {
        self.framesPerSecond = framesPerSecond
        self.minBitrateBps = minBitrateBps
        self.maxBitrateBps = maxBitrateBps
        self.pixelBudgetPerSecond = pixelBudgetPerSecond
    }

    package init(performanceMode: CapturePerformanceMode) {
        let budget = SharedCapturePerformanceBudget(performanceMode: performanceMode)
        switch performanceMode {
        case .automatic:
            self.init(
                framesPerSecond: budget.framesPerSecond,
                minBitrateBps: 2_000_000,
                maxBitrateBps: 24_000_000,
                pixelBudgetPerSecond: budget.pixelBudgetPerSecond
            )
        case .smooth:
            self.init(
                framesPerSecond: budget.framesPerSecond,
                minBitrateBps: 3_000_000,
                maxBitrateBps: 32_000_000,
                pixelBudgetPerSecond: budget.pixelBudgetPerSecond
            )
        case .powerEfficient:
            self.init(
                framesPerSecond: budget.framesPerSecond,
                minBitrateBps: 1_000_000,
                maxBitrateBps: 12_000_000,
                pixelBudgetPerSecond: budget.pixelBudgetPerSecond
            )
        }
    }

    package func outputDimensions(forWidth width: Int32, height: Int32) -> (width: Int32, height: Int32) {
        guard width > 0, height > 0 else {
            return (width, height)
        }

        let budget = SharedCapturePerformanceBudget(
            framesPerSecond: framesPerSecond,
            pixelBudgetPerSecond: pixelBudgetPerSecond
        )
        let dimensions = budget.captureDimensions(
            for: CapturePixelDimensions(width: Int(width), height: Int(height))
        )
        return (
            width: Int32(dimensions.width),
            height: Int32(dimensions.height)
        )
    }
}

package final class WebRTCFrameMailbox<Frame: Sendable>: @unchecked Sendable {
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

package enum SignalingMessageType: String, Codable {
    case viewerReady = "viewer_ready"
    case offer
    case answer
    case iceCandidate = "ice_candidate"
    case iceComplete = "ice_complete"
    case ready
    case stopped
    case error
}

package struct SignalingInboundMessage: Decodable {
    package let type: String?
    package let sdp: String?
    package let candidate: String?
    package let sdpMid: String?
    package let sdpMLineIndex: Int?
}

package struct SignalingOutboundMessage: Encodable {
    package let type: SignalingMessageType
    package let reason: String?
    package let sdp: String?
    package let candidate: String?
    package let sdpMid: String?
    package let sdpMLineIndex: Int?

    package init(
        type: SignalingMessageType,
        reason: String? = nil,
        sdp: String? = nil,
        candidate: String? = nil,
        sdpMid: String? = nil,
        sdpMLineIndex: Int? = nil
    ) {
        self.type = type
        self.reason = reason
        self.sdp = sdp
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
}

package enum WebRTCIceServerProvider {
    nonisolated static func configuredURLStrings() -> [String] {
        guard let raw = ProcessInfo.processInfo.environment["VOIDDISPLAY_WEBRTC_ICE_SERVERS"] else {
            return []
        }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated static func browserBootstrapJSON() -> String {
        let urls = configuredURLStrings()
        let payload: [String: Any] = [
            "iceServers": urls.isEmpty ? [] : [["urls": urls]]
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              var json = String(data: data, encoding: .utf8) else {
            return #"{"iceServers":[]}"#
        }
        json = json.replacingOccurrences(of: "</script>", with: "<\\/script>")
        return json
    }
}

#if canImport(WebRTC)

private extension WebRTCIceServerProvider {
    nonisolated static func configuredServers() -> [RTCIceServer] {
        let urls = configuredURLStrings()
        guard !urls.isEmpty else { return [] }
        return [RTCIceServer(urlStrings: urls)]
    }
}

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

package struct WebRTCCodecPreferenceDescriptor: Sendable, Equatable {
    package let name: String
    package let payloadType: Int?
    package let parameters: [String: String]

    package init(
        name: String,
        payloadType: Int?,
        parameters: [String: String]
    ) {
        self.name = name
        self.payloadType = payloadType
        self.parameters = parameters
    }
}

package enum WebRTCCodecPreference {
    package nonisolated static func preferredVP8DescriptorIndexes(
        from descriptors: [WebRTCCodecPreferenceDescriptor]
    ) -> [Int]? {
        let vp8Indexes = descriptors.indices.filter {
            descriptors[$0].name.caseInsensitiveCompare(kRTCVp8CodecName) == .orderedSame
        }
        guard !vp8Indexes.isEmpty else { return nil }

        let vp8PayloadTypes = Set(vp8Indexes.compactMap { descriptors[$0].payloadType })
        let rtxIndexes = descriptors.indices.filter { index in
            let descriptor = descriptors[index]
            guard descriptor.name.caseInsensitiveCompare(kRTCRtxCodecName) == .orderedSame,
                  let apt = descriptor.parameters["apt"].flatMap(Int.init) else {
                return false
            }
            return vp8PayloadTypes.contains(apt)
        }
        return vp8Indexes + rtxIndexes
    }

    package nonisolated static func preferredVP8Codecs(
        from codecs: [RTCRtpCodecCapability]
    ) -> [RTCRtpCodecCapability]? {
        let descriptors = codecs.map {
            WebRTCCodecPreferenceDescriptor(
                name: $0.name,
                payloadType: $0.preferredPayloadType?.intValue,
                parameters: $0.parameters
            )
        }
        guard let indexes = preferredVP8DescriptorIndexes(from: descriptors) else {
            return nil
        }
        return indexes.map { codecs[$0] }
    }
}

package final class WebRTCMediaPipeline: @unchecked Sendable {
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
        var consumedFrameCount = 0
    }

    private static let sslInitialized: Void = {
        RTCInitializeSSL()
    }()

    private let factory: RTCPeerConnectionFactory
    nonisolated(unsafe) package let videoSource: RTCVideoSource
    nonisolated(unsafe) package let videoTrack: RTCVideoTrack
    nonisolated(unsafe) private let capturer: RTCVideoCapturer
    private let queue = DispatchQueue(
        label: "com.developerchen.voiddisplay.webrtc.media",
        qos: .userInitiated
    )
    private let profile = Mutex(WebRTCStreamingProfile(performanceMode: .automatic))
    private let runtimeDiagnostics = Mutex(RuntimeDiagnostics())
    nonisolated(unsafe) private var frameMailbox: WebRTCFrameMailbox<PendingFrame>!
    nonisolated(unsafe) private var lastFormat: (width: Int32, height: Int32, framesPerSecond: Int)?
    nonisolated(unsafe) private var timestampSequencer = WebRTCFrameTimestampSequencer()

    nonisolated package init() {
        _ = Self.sslInitialized
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
        self.videoSource = factory.videoSource()
        self.videoTrack = factory.videoTrack(with: videoSource, trackId: "screen-video-track")
        self.capturer = RTCVideoCapturer(delegate: videoSource)
        self.frameMailbox = WebRTCFrameMailbox(
            scheduler: { [weak self] operation in
                self?.queue.async(execute: operation)
            },
            consumer: { [weak self] frame in
                self?.consume(frame)
            }
        )
    }

    nonisolated package func makePeerConnection() -> RTCPeerConnection? {
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

    nonisolated package func preferredVP8Codecs() -> [RTCRtpCodecCapability]? {
        let capabilities = factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
        return WebRTCCodecPreference.preferredVP8Codecs(from: capabilities.codecs)
    }

    nonisolated package func updateEncodingProfile(_ profile: WebRTCStreamingProfile) {
        self.profile.withLock { $0 = profile }
        queue.async { [weak self] in
            guard let self, let lastFormat = self.lastFormat else { return }
            let dimensions = profile.outputDimensions(
                forWidth: lastFormat.width,
                height: lastFormat.height
            )
            self.videoSource.adaptOutputFormat(
                toWidth: dimensions.width,
                height: dimensions.height,
                fps: Int32(profile.framesPerSecond)
            )
            self.lastFormat = (
                width: lastFormat.width,
                height: lastFormat.height,
                framesPerSecond: profile.framesPerSecond
            )
        }
    }

    nonisolated package func submitFrame(pixelBuffer: CVPixelBuffer, ptsUs: UInt64) {
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
        let outputDimensions = currentProfile.outputDimensions(forWidth: width, height: height)
        if lastFormat?.width != width ||
            lastFormat?.height != height ||
            lastFormat?.framesPerSecond != currentProfile.framesPerSecond {
            videoSource.adaptOutputFormat(
                toWidth: outputDimensions.width,
                height: outputDimensions.height,
                fps: Int32(currentProfile.framesPerSecond)
            )
            lastFormat = (width, height, currentProfile.framesPerSecond)
        }

        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let timestampNs = timestampSequencer.nextTimestampNs(
            ptsUs: pendingFrame.ptsUs,
            framesPerSecond: currentProfile.framesPerSecond
        )
        let frame = RTCVideoFrame(
            buffer: rtcBuffer,
            rotation: ._0,
            timeStampNs: timestampNs
        )
        let shouldLogFirstForwardedFrame = runtimeDiagnostics.withLock { diagnostics -> Bool in
            diagnostics.consumedFrameCount += 1
            return diagnostics.consumedFrameCount == 1
        }
        if shouldLogFirstForwardedFrame {
            AppLog.web.info(
                "WebRTC media pipeline forwarded first RTC frame input=\(width, privacy: .public)x\(height, privacy: .public) output=\(outputDimensions.width, privacy: .public)x\(outputDimensions.height, privacy: .public) fps=\(currentProfile.framesPerSecond, privacy: .public) ptsUs=\(pendingFrame.ptsUs, privacy: .public) timestampNs=\(timestampNs, privacy: .public)."
            )
        }
        videoSource.capturer(capturer, didCapture: frame)
    }
}

#endif
