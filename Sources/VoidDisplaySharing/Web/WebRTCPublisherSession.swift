import Foundation
import CoreVideo
import VoidDisplayObservability
import Synchronization

#if canImport(WebRTC)
@preconcurrency import WebRTC

package final class WebRTCPublisherSession: NSObject, @unchecked Sendable {
    nonisolated private static let maintainResolutionPreference = NSNumber(
        value: RTCDegradationPreference.maintainResolution.rawValue
    )

    private enum State {
        case idle
        case starting(Task<Void, any Error>)
        case started
        case closed
    }

    private struct VideoTransceiverBinding {
        let codec: WebRTCVideoCodec
        let transceiver: RTCRtpTransceiver
    }

    nonisolated(unsafe) private let peerConnection: RTCPeerConnection
    private let mediaPipeline: WebRTCMediaPipeline
    private let relayClient: any RelayHTTPClienting
    private let roomID: String
    private let stateLock = Mutex<State>(.idle)
    private let profileState: Mutex<WebRTCStreamingProfile>
    private let activeCodecsState = Mutex<Set<WebRTCVideoCodec>>([])
    private let publisherIDState = Mutex<String?>(nil)
    private let pendingPublisherCandidates = Mutex<[RTCIceCandidate]>([])
    nonisolated(unsafe) private var videoTransceivers: [VideoTransceiverBinding] = []
    nonisolated(unsafe) private var diagnosticsTask: Task<Void, Never>?

    package nonisolated init?(
        roomID: String,
        relayClient: any RelayHTTPClienting,
        mediaPipeline: WebRTCMediaPipeline,
        initialProfile: WebRTCStreamingProfile
    ) {
        guard let peerConnection = mediaPipeline.makePeerConnection() else { return nil }
        self.peerConnection = peerConnection
        self.relayClient = relayClient
        self.roomID = roomID
        self.mediaPipeline = mediaPipeline
        self.profileState = Mutex(initialProfile)
        super.init()
        self.peerConnection.delegate = self
        self.mediaPipeline.updateEncodingProfile(initialProfile)
    }

    package nonisolated func start() async throws {
        let task = stateLock.withLock { state -> Task<Void, any Error> in
            switch state {
            case .started:
                return Task {}
            case .starting(let task):
                return task
            case .closed:
                return Task { throw PublisherSessionError.closed }
            case .idle:
                let task = Task<Void, any Error> { [weak self] in
                    guard let self else { throw PublisherSessionError.closed }
                    try await self.startInternal()
                }
                state = .starting(task)
                return task
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { [weak self] in
                task.cancel()
                self?.close()
            }
            stateLock.withLock {
                if case .starting = $0 {
                    $0 = .started
                }
            }
        } catch {
            stateLock.withLock {
                if case .starting = $0 {
                    $0 = .idle
                }
            }
            throw error
        }
    }

    package nonisolated func updateEncodingProfile(_ profile: WebRTCStreamingProfile) {
        profileState.withLock { $0 = profile }
        mediaPipeline.updateEncodingProfile(profile)
        let activeCodecs = activeCodecsState.withLock { $0 }
        for binding in videoTransceivers {
            configureDesktopVideoSender(
                binding.transceiver.sender,
                codec: binding.codec,
                profile: profile,
                isActive: activeCodecs.contains(binding.codec)
            )
        }
        updateBandwidthEstimate(profile: profile, activeCodecs: activeCodecs)
    }

    package nonisolated func updateActiveCodecs(_ activeCodecs: Set<WebRTCVideoCodec>) {
        let configuredCodecs = Set(videoTransceivers.map(\.codec))
        let nextActiveCodecs = activeCodecs.intersection(configuredCodecs)
        activeCodecsState.withLock { $0 = nextActiveCodecs }
        mediaPipeline.updateActiveCodecs(nextActiveCodecs)
        let profile = profileState.withLock { $0 }
        for binding in videoTransceivers {
            configureDesktopVideoSender(
                binding.transceiver.sender,
                codec: binding.codec,
                profile: profile,
                isActive: nextActiveCodecs.contains(binding.codec)
            )
        }
        updateBandwidthEstimate(profile: profile, activeCodecs: nextActiveCodecs)
        let activeSummary = nextActiveCodecs.map(\.logName).sorted().joined(separator: ",")
        AppLog.web.info("WebRTC publisher active codecs updated active=\(activeSummary, privacy: .public).")
    }

    package nonisolated func submitFrame(pixelBuffer: CVPixelBuffer, ptsUs: UInt64) {
        mediaPipeline.submitFrame(pixelBuffer: pixelBuffer, ptsUs: ptsUs)
    }

    package nonisolated func close() {
        stateLock.withLock { $0 = .closed }
        let publisherID = publisherIDState.withLock { publisherID -> String? in
            let current = publisherID
            publisherID = nil
            return current
        }
        pendingPublisherCandidates.withLock { $0.removeAll() }
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        peerConnection.close()
        guard let publisherID else { return }
        Task { [relayClient, roomID, publisherID] in
            await relayClient.stopPublisher(roomID: roomID, publisherID: publisherID)
        }
    }

    private nonisolated func startInternal() async throws {
        let capabilitySummary = mediaPipeline.senderVideoCodecCapabilitySummary()
        AppLog.web.info("WebRTC sender video capabilities \(capabilitySummary, privacy: .public).")
        guard let av1Codecs = mediaPipeline.requiredCodecs(for: .av1) else {
            throw PublisherSessionError.av1Unavailable
        }
        let av1Transceiver = try addVideoTransceiver(
            codec: .av1,
            track: mediaPipeline.av1VideoTrack,
            codecs: av1Codecs
        )
        let configuredTransceivers = [VideoTransceiverBinding(codec: .av1, transceiver: av1Transceiver)]
        let configuredCodecs: Set<WebRTCVideoCodec> = [.av1]
        videoTransceivers = configuredTransceivers
        let initialActiveCodecs = activeCodecsState.withLock { $0.intersection(configuredCodecs) }
        mediaPipeline.updateActiveCodecs(initialActiveCodecs)
        let initialProfile = profileState.withLock { $0 }
        for binding in configuredTransceivers {
            configureDesktopVideoSender(
                binding.transceiver.sender,
                codec: binding.codec,
                profile: initialProfile,
                isActive: initialActiveCodecs.contains(binding.codec)
            )
        }
        updateBandwidthEstimate(profile: initialProfile, activeCodecs: initialActiveCodecs)
        AppLog.web.info("WebRTC publisher transceiver configured AV1 codecs=\(av1Codecs.count, privacy: .public).")

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer = try await createOffer(constraints: constraints)
        try await setLocalDescription(offer)
        try throwIfClosed()
        let finalOffer = peerConnection.localDescription ?? offer
        let localCodecSummary = WebRTCCodecPreference.sdpVideoCodecSummary(from: finalOffer.sdp)
        AppLog.web.info("WebRTC publisher local SDP video codecs \(localCodecSummary, privacy: .public).")
        let response = try await relayClient.publisherOffer(roomID: roomID, sdp: finalOffer.sdp)
        publisherIDState.withLock { $0 = response.publisherID }
        flushPendingPublisherCandidates(publisherID: response.publisherID)
        if isClosed {
            publisherIDState.withLock { $0 = nil }
            pendingPublisherCandidates.withLock { $0.removeAll() }
            await relayClient.stopPublisher(roomID: roomID, publisherID: response.publisherID)
            throw PublisherSessionError.closed
        }
        let answer = RTCSessionDescription(type: .answer, sdp: response.sdp)
        try await setRemoteDescription(answer)
        startDiagnosticsLoop()
        AppLog.web.info("WebRTC publisher connected to relay room \(self.roomID, privacy: .public).")
    }

    private nonisolated func addVideoTransceiver(
        codec: WebRTCVideoCodec,
        track: RTCVideoTrack,
        codecs: [RTCRtpCodecCapability]
    ) throws -> RTCRtpTransceiver {
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendOnly
        transceiverInit.streamIds = ["screen"]
        guard let transceiver = peerConnection.addTransceiver(with: track, init: transceiverInit) else {
            throw PublisherSessionError.videoTransceiverUnavailable(codec)
        }
        do {
            try transceiver.setCodecPreferences(codecs, error: ())
        } catch {
            throw PublisherSessionError.codecPreferencesFailed("\(codec.logName): \(String(describing: error))")
        }
        return transceiver
    }

    private nonisolated func createOffer(constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            peerConnection.offer(for: constraints) { offer, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let offer else {
                    continuation.resume(throwing: PublisherSessionError.offerMissing)
                    return
                }
                continuation.resume(returning: offer)
            }
        }
    }

    private nonisolated func setLocalDescription(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private nonisolated func setRemoteDescription(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private nonisolated var isClosed: Bool {
        stateLock.withLock { state in
            if case .closed = state { return true }
            return false
        }
    }

    private nonisolated func throwIfClosed() throws {
        if isClosed {
            throw PublisherSessionError.closed
        }
    }

    private nonisolated func configureDesktopVideoSender(
        _ sender: RTCRtpSender?,
        codec: WebRTCVideoCodec,
        profile: WebRTCStreamingProfile,
        isActive: Bool
    ) {
        guard let sender else { return }
        let parameters = sender.parameters
        if parameters.encodings.isEmpty {
            parameters.encodings = [RTCRtpEncodingParameters()]
        }
        let sourceDimensions = profile.sourceVideoSpec.dimensions
        let outputDimensions = profile.outputDimensions(
            for: codec,
            width: Int32(sourceDimensions.width),
            height: Int32(sourceDimensions.height)
        )
        let bitrateLimits = profile.bitrateLimits(
            for: codec,
            outputWidth: outputDimensions.width,
            outputHeight: outputDimensions.height
        )
        let framesPerSecond = profile.framesPerSecond(for: codec)
        for encoding in parameters.encodings {
            encoding.isActive = isActive
            encoding.maxBitrateBps = NSNumber(value: bitrateLimits.maxBitrateBps)
            encoding.minBitrateBps = NSNumber(value: bitrateLimits.minBitrateBps)
            encoding.maxFramerate = NSNumber(value: framesPerSecond)
            encoding.scaleResolutionDownBy = NSNumber(value: 1.0)
            encoding.bitratePriority = 4.0
            encoding.networkPriority = .high
        }
        parameters.degradationPreference = Self.maintainResolutionPreference
        sender.parameters = parameters
    }

    private nonisolated func updateBandwidthEstimate(
        profile: WebRTCStreamingProfile,
        activeCodecs: Set<WebRTCVideoCodec>
    ) {
        let sourceDimensions = profile.sourceVideoSpec.dimensions
        let codecsForBudget = activeCodecs.isEmpty ? Set(WebRTCVideoCodec.allCases) : activeCodecs
        let limits = codecsForBudget.map { codec in
            let outputDimensions = profile.outputDimensions(
                for: codec,
                width: Int32(sourceDimensions.width),
                height: Int32(sourceDimensions.height)
            )
            return profile.bitrateLimits(
                for: codec,
                outputWidth: outputDimensions.width,
                outputHeight: outputDimensions.height
            )
        }
        let minBitrateBps = limits.map(\.minBitrateBps).min() ?? profile.minBitrateBps
        let maxBitrateBps = limits.map(\.maxBitrateBps).reduce(0, +)
        _ = peerConnection.setBweMinBitrateBps(
            NSNumber(value: minBitrateBps),
            currentBitrateBps: nil,
            maxBitrateBps: NSNumber(value: max(maxBitrateBps, profile.maxBitrateBps))
        )
    }

    private nonisolated func startDiagnosticsLoop() {
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { [weak self] in
            await self?.runDiagnosticsLoop()
        }
    }

    private nonisolated func runDiagnosticsLoop() async {
        while !Task.isCancelled, !isClosed {
            await logSenderDiagnostics()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private nonisolated func logSenderDiagnostics() async {
        let bindings = videoTransceivers
        for binding in bindings {
            let report = await statistics(for: binding.transceiver.sender)
            logOutboundVideoStats(report: report, codec: binding.codec)
        }
    }

    private nonisolated func statistics(for sender: RTCRtpSender) async -> RTCStatisticsReport {
        await withCheckedContinuation { continuation in
            peerConnection.statistics(for: sender) { report in
                continuation.resume(returning: report)
            }
        }
    }

    private nonisolated func logOutboundVideoStats(report: RTCStatisticsReport, codec: WebRTCVideoCodec) {
        for statistic in report.statistics.values where statistic.type == "outbound-rtp" {
            let values = statistic.values
            let kind = (values["kind"] ?? values["mediaType"])?.description.lowercased()
            guard kind == nil || kind == "video" else { continue }
            let width = values["frameWidth"]?.description ?? "unknown"
            let height = values["frameHeight"]?.description ?? "unknown"
            let fps = values["framesPerSecond"]?.description ?? "unknown"
            let targetBitrate = values["targetBitrate"]?.description ?? "unknown"
            let qualityLimitationReason = values["qualityLimitationReason"]?.description ?? "unknown"
            let encoderImplementation = values["encoderImplementation"]?.description ?? "unknown"
            AppLog.web.info(
                "WebRTC publisher outbound stats codec=\(codec.logName, privacy: .public) encoded=\(width, privacy: .public)x\(height, privacy: .public) fps=\(fps, privacy: .public) targetBitrate=\(targetBitrate, privacy: .public) qualityLimitationReason=\(qualityLimitationReason, privacy: .public) encoder=\(encoderImplementation, privacy: .public)."
            )
            return
        }
    }

    private nonisolated func sendPublisherCandidate(_ candidate: RTCIceCandidate) {
        guard let publisherID = publisherIDState.withLock({ $0 }) else {
            pendingPublisherCandidates.withLock { $0.append(candidate) }
            return
        }
        Task { [relayClient, roomID, publisherID] in
            try? await relayClient.publisherCandidate(
                roomID: roomID,
                publisherID: publisherID,
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: Int32(candidate.sdpMLineIndex)
            )
        }
    }

    private nonisolated func flushPendingPublisherCandidates(publisherID: String) {
        let candidates = pendingPublisherCandidates.withLock { candidates -> [RTCIceCandidate] in
            let pending = candidates
            candidates.removeAll()
            return pending
        }
        for candidate in candidates {
            Task { [relayClient, roomID, publisherID] in
                try? await relayClient.publisherCandidate(
                    roomID: roomID,
                    publisherID: publisherID,
                    candidate: candidate.sdp,
                    sdpMid: candidate.sdpMid,
                    sdpMLineIndex: Int32(candidate.sdpMLineIndex)
                )
            }
        }
    }
}

extension WebRTCPublisherSession: RTCPeerConnectionDelegate {
    package nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    package nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    package nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    package nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    package nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    package nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    package nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    package nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .connected:
            AppLog.web.info("WebRTC publisher state changed to \(String(describing: newState), privacy: .public).")
        case .failed, .closed, .disconnected:
            AppLog.web.warning("WebRTC publisher state changed to \(String(describing: newState), privacy: .public).")
        default:
            break
        }
    }
    package nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    package nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        sendPublisherCandidate(candidate)
    }

    package nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChangeLocalCandidate candidate: RTCIceCandidate) {
        sendPublisherCandidate(candidate)
    }
}

package enum PublisherSessionError: Error, LocalizedError, Equatable {
    case closed
    case av1Unavailable
    case videoTransceiverUnavailable(WebRTCVideoCodec)
    case codecPreferencesFailed(String)
    case offerMissing

    package var errorDescription: String? {
        switch self {
        case .closed:
            "Publisher session is closed."
        case .av1Unavailable:
            String(localized: "This Mac's WebRTC stack did not expose AV1 video encoding.")
        case .videoTransceiverUnavailable(let codec):
            "WebRTC publisher \(codec.logName) video transceiver is unavailable."
        case .codecPreferencesFailed(let reason):
            "Failed to set publisher codec preferences: \(reason)"
        case .offerMissing:
            "WebRTC publisher offer is missing."
        }
    }
}
#endif
