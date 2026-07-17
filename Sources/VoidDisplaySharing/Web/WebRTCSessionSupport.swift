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

package enum WebRTCVideoCodec: String, CaseIterable, Sendable {
    case av1

    package var logName: String {
        switch self {
        case .av1:
            "AV1"
        }
    }
}

package struct WebRTCStreamingProfile: Sendable, Equatable {
    private static let av1SourceBitsPerPixel: Double = 0.10
    private static let av1PowerEfficientBitsPerPixel: Double = 0.05

    package let performanceMode: CapturePerformanceMode
    package let sourceVideoSpec: SourceVideoSpec
    package let framesPerSecond: Int
    package let minBitrateBps: Int
    package let maxBitrateBps: Int
    package let pixelBudgetPerSecond: Int64?

    package init(
        performanceMode: CapturePerformanceMode,
        sourceVideoSpec: SourceVideoSpec,
        framesPerSecond: Int,
        pixelBudgetPerSecond: Int64?
    ) {
        self.performanceMode = performanceMode
        self.sourceVideoSpec = sourceVideoSpec
        self.framesPerSecond = max(1, framesPerSecond)
        self.pixelBudgetPerSecond = pixelBudgetPerSecond
        let sourceDimensions = sourceVideoSpec.dimensions
        let maxBitrateBps = Self.targetMaxBitrateBps(
            for: .av1,
            dimensions: sourceDimensions,
            framesPerSecond: self.framesPerSecond,
            performanceMode: performanceMode
        )
        self.maxBitrateBps = maxBitrateBps
        self.minBitrateBps = Self.targetMinBitrateBps(maxBitrateBps: maxBitrateBps)
    }

    package init(
        performanceMode: CapturePerformanceMode,
        sourceVideoSpec: SourceVideoSpec = .defaultShared
    ) {
        let budget = SharedCapturePerformanceBudget(performanceMode: performanceMode)
        let sourceFramesPerSecond = sourceVideoSpec.framesPerSecond
        switch performanceMode {
        case .automatic:
            self.init(
                performanceMode: performanceMode,
                sourceVideoSpec: sourceVideoSpec,
                framesPerSecond: sourceFramesPerSecond,
                pixelBudgetPerSecond: nil
            )
        case .smooth:
            self.init(
                performanceMode: performanceMode,
                sourceVideoSpec: sourceVideoSpec,
                framesPerSecond: sourceFramesPerSecond,
                pixelBudgetPerSecond: nil
            )
        case .powerEfficient:
            self.init(
                performanceMode: performanceMode,
                sourceVideoSpec: sourceVideoSpec,
                framesPerSecond: min(sourceFramesPerSecond, budget.framesPerSecond),
                pixelBudgetPerSecond: SharedCapturePerformanceBudget.powerEfficientPixelBudgetPerSecond
            )
        }
    }

    package func bitrateLimits(
        for codec: WebRTCVideoCodec,
        outputWidth: Int32,
        outputHeight: Int32
    ) -> (minBitrateBps: Int, maxBitrateBps: Int) {
        let maxBitrateBps = Self.targetMaxBitrateBps(
            for: codec,
            dimensions: CapturePixelDimensions(width: Int(outputWidth), height: Int(outputHeight)),
            framesPerSecond: framesPerSecond(for: codec),
            performanceMode: performanceMode
        )
        return (
            minBitrateBps: Self.targetMinBitrateBps(maxBitrateBps: maxBitrateBps),
            maxBitrateBps: maxBitrateBps
        )
    }

    package func outputDimensions(
        for codec: WebRTCVideoCodec,
        width: Int32,
        height: Int32
    ) -> (width: Int32, height: Int32) {
        outputDimensions(
            forWidth: width,
            height: height,
            framesPerSecond: framesPerSecond(for: codec),
            pixelBudgetPerSecond: pixelBudgetPerSecond(for: codec)
        )
    }

    package func outputDimensions(forWidth width: Int32, height: Int32) -> (width: Int32, height: Int32) {
        outputDimensions(
            forWidth: width,
            height: height,
            framesPerSecond: framesPerSecond,
            pixelBudgetPerSecond: pixelBudgetPerSecond
        )
    }

    package func framesPerSecond(for codec: WebRTCVideoCodec) -> Int {
        framesPerSecond
    }

    package func outputVideoSpec(for codec: WebRTCVideoCodec) -> SourceVideoSpec {
        let sourceDimensions = sourceVideoSpec.dimensions
        let outputDimensions = outputDimensions(
            for: codec,
            width: Int32(sourceDimensions.width),
            height: Int32(sourceDimensions.height)
        )
        return SourceVideoSpec(
            width: Int(outputDimensions.width),
            height: Int(outputDimensions.height),
            framesPerSecond: framesPerSecond(for: codec)
        )
    }

    private func pixelBudgetPerSecond(for codec: WebRTCVideoCodec) -> Int64? {
        pixelBudgetPerSecond
    }

    private func outputDimensions(
        forWidth width: Int32,
        height: Int32,
        framesPerSecond: Int,
        pixelBudgetPerSecond: Int64?
    ) -> (width: Int32, height: Int32) {
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

    private static func targetMaxBitrateBps(
        for codec: WebRTCVideoCodec,
        dimensions: CapturePixelDimensions,
        framesPerSecond: Int,
        performanceMode: CapturePerformanceMode
    ) -> Int {
        let pixelRate = Double(dimensions.pixelCount) * Double(max(1, framesPerSecond))
        let bitsPerPixel: Double = switch (codec, performanceMode) {
        case (.av1, .powerEfficient):
            av1PowerEfficientBitsPerPixel
        case (.av1, _):
            av1SourceBitsPerPixel
        }
        let target = Int((pixelRate * bitsPerPixel).rounded())
        return max(2_000_000, target)
    }

    private static func targetMinBitrateBps(maxBitrateBps: Int) -> Int {
        max(1_500_000, maxBitrateBps / 4)
    }
}

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

package enum SignalingMessageType: String, Codable {
    case viewerReady = "viewer_ready"
    case offer
    case answer
    case iceCandidate = "ice_candidate"
    case iceComplete = "ice_complete"
    case ready
    case codecPending = "codec_pending"
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

package struct SourceVideoSpecSignalPayload: Codable, Sendable, Equatable {
    package let width: Int
    package let height: Int
    package let framesPerSecond: Int

    package init(spec: SourceVideoSpec) {
        self.width = spec.dimensions.width
        self.height = spec.dimensions.height
        self.framesPerSecond = spec.framesPerSecond
    }
}

package struct SignalingOutboundMessage: Encodable {
    package let type: SignalingMessageType
    package let reason: String?
    package let sdp: String?
    package let candidate: String?
    package let sdpMid: String?
    package let sdpMLineIndex: Int?
    package let sourceVideoSpec: SourceVideoSpecSignalPayload?

    package init(
        type: SignalingMessageType,
        reason: String? = nil,
        sdp: String? = nil,
        candidate: String? = nil,
        sdpMid: String? = nil,
        sdpMLineIndex: Int? = nil,
        sourceVideoSpec: SourceVideoSpecSignalPayload? = nil
    ) {
        self.type = type
        self.reason = reason
        self.sdp = sdp
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.sourceVideoSpec = sourceVideoSpec
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

extension WebRTCVideoCodec {
    package var codecName: String {
        switch self {
        case .av1:
            "AV1"
        }
    }
}

package enum WebRTCCodecPreference {
    package nonisolated static func requiredDescriptorIndexes(
        for codec: WebRTCVideoCodec,
        from descriptors: [WebRTCCodecPreferenceDescriptor]
    ) -> [Int]? {
        let primaryIndexes = descriptors.indices.filter {
            descriptors[$0].name.caseInsensitiveCompare(codec.codecName) == .orderedSame
        }
        guard !primaryIndexes.isEmpty else { return nil }

        let primaryPayloadTypes = Set(primaryIndexes.compactMap { descriptors[$0].payloadType })
        let rtxIndexes = descriptors.indices.filter { index in
            let descriptor = descriptors[index]
            guard descriptor.name.caseInsensitiveCompare(kRTCRtxCodecName) == .orderedSame,
                  let apt = descriptor.parameters["apt"].flatMap(Int.init) else {
                return false
            }
            return primaryPayloadTypes.contains(apt)
        }
        return primaryIndexes + rtxIndexes
    }

    package nonisolated static func requiredCodecs(
        for codec: WebRTCVideoCodec,
        from codecs: [RTCRtpCodecCapability]
    ) -> [RTCRtpCodecCapability]? {
        let descriptors = codecs.map {
            WebRTCCodecPreferenceDescriptor(
                name: $0.name,
                payloadType: $0.preferredPayloadType?.intValue,
                parameters: $0.parameters
            )
        }
        guard let indexes = requiredDescriptorIndexes(for: codec, from: descriptors) else {
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
        let av1Descriptors = descriptors.filter {
            $0.name.caseInsensitiveCompare(WebRTCVideoCodec.av1.codecName) == .orderedSame
        }
        let otherCodecCount = descriptors.count - av1Descriptors.count
        return [
            "AV1=\(capabilityProbeSummary(from: av1Descriptors))",
            "unsupportedVideoCodecCount=\(otherCodecCount)",
        ].joined(separator: "; ")
    }

    private nonisolated static func capabilityProbeSummary(
        from descriptors: [WebRTCCodecPreferenceDescriptor]
    ) -> String {
        guard !descriptors.isEmpty else { return "missing" }
        return descriptors.map { descriptor in
            let payloadType = descriptor.payloadType.map(String.init) ?? "none"
            let parameters = descriptor.parameters
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            return "\(descriptor.name)(pt=\(payloadType),fmtp=\(parameters.isEmpty ? "none" : parameters))"
        }
        .joined(separator: ",")
    }

    package nonisolated static func sdpVideoCodecSummary(from sdp: String) -> String {
        let lines = sdp.split(whereSeparator: \.isNewline).map(String.init)
        var currentVideoPayloadTypes: [String] = []
        var currentPayloadNames: [String: String] = [:]
        var isVideoMedia = false
        var summary: [String] = []
        var unexpectedCodecCount = 0

        func flushVideoMedia() {
            guard isVideoMedia else { return }
            for payloadType in currentVideoPayloadTypes {
                guard let name = currentPayloadNames[payloadType] else { continue }
                let normalizedName = name.lowercased()
                guard normalizedName == "av1" || normalizedName == "rtx" else {
                    unexpectedCodecCount += 1
                    continue
                }
                summary.append("\(payloadType):\(name)")
            }
        }

        for line in lines {
            if line.hasPrefix("m=") {
                flushVideoMedia()
                isVideoMedia = line.hasPrefix("m=video ")
                currentVideoPayloadTypes = []
                currentPayloadNames = [:]
                if isVideoMedia {
                    let parts = line.split(separator: " ").map(String.init)
                    if parts.count > 3 {
                        currentVideoPayloadTypes = Array(parts.dropFirst(3))
                    }
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
            currentPayloadNames[payloadType] = codecName
        }
        flushVideoMedia()

        let text = summary.isEmpty ? "none" : summary.joined(separator: ",")
        return "\(text); unexpectedVideoCodecCount=\(unexpectedCodecCount)"
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
