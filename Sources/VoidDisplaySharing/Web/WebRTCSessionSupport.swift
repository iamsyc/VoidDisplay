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
    package static let h264AutomaticPixelBudgetPerSecond: Int64 = 26_542_080
    package static let h264SmoothPixelBudgetPerSecond: Int64 = 26_542_080
    package static let h264PowerEfficientPixelBudgetPerSecond: Int64 = 15_552_000
    private static let h264Level31MaxMacroblocksPerFrame = 3_600
    private static let h264Level31MaxMacroblocksPerSecond = 108_000

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
                framesPerSecond: 30,
                minBitrateBps: 1_500_000,
                maxBitrateBps: 8_000_000,
                pixelBudgetPerSecond: Self.h264AutomaticPixelBudgetPerSecond
            )
        case .smooth:
            self.init(
                framesPerSecond: budget.framesPerSecond,
                minBitrateBps: 1_500_000,
                maxBitrateBps: 8_000_000,
                pixelBudgetPerSecond: Self.h264SmoothPixelBudgetPerSecond
            )
        case .powerEfficient:
            self.init(
                framesPerSecond: budget.framesPerSecond,
                minBitrateBps: 800_000,
                maxBitrateBps: 5_000_000,
                pixelBudgetPerSecond: Self.h264PowerEfficientPixelBudgetPerSecond
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
        let h264Dimensions = Self.constrainToH264Level31(
            dimensions,
            framesPerSecond: framesPerSecond
        )
        return (
            width: Int32(h264Dimensions.width),
            height: Int32(h264Dimensions.height)
        )
    }

    private static func constrainToH264Level31(
        _ dimensions: CapturePixelDimensions,
        framesPerSecond: Int
    ) -> CapturePixelDimensions {
        let framesPerSecond = max(1, framesPerSecond)
        let frameMacroblockBudget = min(
            h264Level31MaxMacroblocksPerFrame,
            h264Level31MaxMacroblocksPerSecond / framesPerSecond
        )
        guard frameMacroblockBudget > 0,
              macroblockCount(for: dimensions) > frameMacroblockBudget else {
            return dimensions
        }

        var constrained = dimensions.constrained(
            toFramePixelBudget: Int64(frameMacroblockBudget * 16 * 16)
        )
        while macroblockCount(for: constrained) > frameMacroblockBudget {
            if constrained.width >= constrained.height {
                constrained = CapturePixelDimensions(
                    width: constrained.width - 2,
                    height: constrained.height
                )
            } else {
                constrained = CapturePixelDimensions(
                    width: constrained.width,
                    height: constrained.height - 2
                )
            }
        }
        return constrained
    }

    private static func macroblockCount(for dimensions: CapturePixelDimensions) -> Int {
        let macroblockWidth = (dimensions.width + 15) / 16
        let macroblockHeight = (dimensions.height + 15) / 16
        return macroblockWidth * macroblockHeight
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
    package nonisolated static func requiredH264DescriptorIndexes(
        from descriptors: [WebRTCCodecPreferenceDescriptor]
    ) -> [Int]? {
        let h264Indexes = descriptors.indices.filter {
            descriptors[$0].name.caseInsensitiveCompare(kRTCH264CodecName) == .orderedSame
        }
        guard !h264Indexes.isEmpty else { return nil }

        let h264PayloadTypes = Set(h264Indexes.compactMap { descriptors[$0].payloadType })
        let rtxIndexes = descriptors.indices.filter { index in
            let descriptor = descriptors[index]
            guard descriptor.name.caseInsensitiveCompare(kRTCRtxCodecName) == .orderedSame,
                  let apt = descriptor.parameters["apt"].flatMap(Int.init) else {
                return false
            }
            return h264PayloadTypes.contains(apt)
        }
        return h264Indexes + rtxIndexes
    }

    package nonisolated static func requiredH264Codecs(
        from codecs: [RTCRtpCodecCapability]
    ) -> [RTCRtpCodecCapability]? {
        let descriptors = codecs.map {
            WebRTCCodecPreferenceDescriptor(
                name: $0.name,
                payloadType: $0.preferredPayloadType?.intValue,
                parameters: $0.parameters
            )
        }
        guard let indexes = requiredH264DescriptorIndexes(from: descriptors) else {
            return nil
        }
        return indexes.map { codecs[$0] }
    }

    package nonisolated static func capabilitySummary(
        from codecs: [RTCRtpCodecCapability]
    ) -> String {
        let descriptors = codecs.map {
            WebRTCCodecPreferenceDescriptor(
                name: $0.name,
                payloadType: $0.preferredPayloadType?.intValue,
                parameters: $0.parameters
            )
        }
        return capabilitySummary(from: descriptors)
    }

    package nonisolated static func capabilitySummary(
        from descriptors: [WebRTCCodecPreferenceDescriptor]
    ) -> String {
        let h264Descriptors = descriptors.filter {
            $0.name.caseInsensitiveCompare(kRTCH264CodecName) == .orderedSame
        }
        let h264Summary = h264Descriptors.map { descriptor in
            let payloadType = descriptor.payloadType.map(String.init) ?? "none"
            let parameters = descriptor.parameters
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ";")
            return "\(descriptor.name)(pt=\(payloadType),params=\(parameters))"
        }
        .joined(separator: ",")
        let h264Text = h264Summary.isEmpty ? "none" : h264Summary
        return "\(h264Text); nonH264CodecCount=\(descriptors.count - h264Descriptors.count)"
    }

    package nonisolated static func sdpVideoCodecSummary(from sdp: String) -> String {
        let lines = sdp.split(whereSeparator: \.isNewline).map(String.init)
        var videoPayloadTypes: [String] = []
        var payloadNames: [String: String] = [:]
        var isVideoMedia = false

        for line in lines {
            if line.hasPrefix("m=") {
                isVideoMedia = line.hasPrefix("m=video ")
                if isVideoMedia {
                    let parts = line.split(separator: " ").map(String.init)
                    videoPayloadTypes = parts.count > 3 ? Array(parts.dropFirst(3)) : []
                }
                continue
            }

            guard isVideoMedia, line.hasPrefix("a=rtpmap:") else { continue }
            let mapping = line.dropFirst("a=rtpmap:".count)
            guard let separator = mapping.firstIndex(of: " ") else { continue }
            let payloadType = String(mapping[..<separator])
            let codecName = mapping[mapping.index(after: separator)...]
                .split(separator: "/", maxSplits: 1)
                .first
                .map(String.init) ?? ""
            payloadNames[payloadType] = codecName
        }

        let summary = videoPayloadTypes.compactMap { payloadType -> String? in
            guard let name = payloadNames[payloadType] else { return nil }
            return "\(payloadType):\(name)"
        }
        return summary.isEmpty ? "none" : summary.joined(separator: ",")
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

    nonisolated package func requiredH264Codecs() -> [RTCRtpCodecCapability]? {
        let capabilities = factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
        return WebRTCCodecPreference.requiredH264Codecs(from: capabilities.codecs)
    }

    nonisolated package func senderVideoCodecCapabilitySummary() -> String {
        let capabilities = factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
        return WebRTCCodecPreference.capabilitySummary(from: capabilities.codecs)
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
