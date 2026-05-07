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

    nonisolated(unsafe) private let peerConnection: RTCPeerConnection
    private let mediaPipeline: WebRTCMediaPipeline
    private let relayClient: any RelayHTTPClienting
    private let roomID: String
    private let stateLock = Mutex<State>(.idle)
    private let profileState: Mutex<WebRTCStreamingProfile>
    private let publisherIDState = Mutex<String?>(nil)
    private let iceGatheringWaiters = Mutex<[CheckedContinuation<Void, Never>]>([])
    private let pendingPublisherCandidates = Mutex<[RTCIceCandidate]>([])
    nonisolated(unsafe) private var videoTransceiver: RTCRtpTransceiver?

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
        configureDesktopVideoSender(videoTransceiver?.sender, profile: profile)
        _ = peerConnection.setBweMinBitrateBps(
            NSNumber(value: profile.minBitrateBps),
            currentBitrateBps: nil,
            maxBitrateBps: NSNumber(value: profile.maxBitrateBps)
        )
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
        resumeIceGatheringWaiters()
        peerConnection.close()
        guard let publisherID else { return }
        Task { [relayClient, roomID, publisherID] in
            await relayClient.stopPublisher(roomID: roomID, publisherID: publisherID)
        }
    }

    private nonisolated func startInternal() async throws {
        let capabilitySummary = mediaPipeline.senderVideoCodecCapabilitySummary()
        AppLog.web.info("WebRTC sender video capabilities \(capabilitySummary, privacy: .public).")
        guard let h264Codecs = mediaPipeline.requiredH264Codecs() else {
            throw PublisherSessionError.h264Unavailable
        }
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendOnly
        transceiverInit.streamIds = ["screen"]
        guard let transceiver = peerConnection.addTransceiver(with: mediaPipeline.videoTrack, init: transceiverInit) else {
            throw PublisherSessionError.videoTransceiverUnavailable
        }
        do {
            try transceiver.setCodecPreferences(h264Codecs, error: ())
        } catch {
            throw PublisherSessionError.codecPreferencesFailed(String(describing: error))
        }
        videoTransceiver = transceiver
        configureDesktopVideoSender(transceiver.sender, profile: profileState.withLock { $0 })
        AppLog.web.info("WebRTC publisher transceiver configured H264 codecs=\(h264Codecs.count, privacy: .public).")

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer = try await createOffer(constraints: constraints)
        try await setLocalDescription(offer)
        await waitForInitialIceGathering()
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
        AppLog.web.info("WebRTC publisher connected to relay room \(self.roomID, privacy: .public).")
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

    private nonisolated func waitForIceGatheringComplete() async {
        guard peerConnection.iceGatheringState != .complete else { return }
        guard !isClosed else { return }
        await withCheckedContinuation { continuation in
            let shouldResumeImmediately = iceGatheringWaiters.withLock { waiters -> Bool in
                guard peerConnection.iceGatheringState != .complete, !isClosed else { return true }
                waiters.append(continuation)
                return false
            }
            if shouldResumeImmediately {
                continuation.resume(returning: ())
            }
        }
    }

    private nonisolated func waitForInitialIceGathering() async {
        let deadline = Date().addingTimeInterval(1)
        while peerConnection.iceGatheringState != .complete, !isClosed, Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        if peerConnection.iceGatheringState != .complete {
            AppLog.web.info(
                "WebRTC publisher continuing before ICE gathering complete state=\(String(describing: self.peerConnection.iceGatheringState), privacy: .public)."
            )
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

    private nonisolated func resumeIceGatheringWaiters() {
        let waiters = iceGatheringWaiters.withLock { waiters -> [CheckedContinuation<Void, Never>] in
            let current = waiters
            waiters.removeAll()
            return current
        }
        for waiter in waiters {
            waiter.resume(returning: ())
        }
    }

    private nonisolated func configureDesktopVideoSender(
        _ sender: RTCRtpSender?,
        profile: WebRTCStreamingProfile
    ) {
        guard let sender else { return }
        let parameters = sender.parameters
        if parameters.encodings.isEmpty {
            parameters.encodings = [RTCRtpEncodingParameters()]
        }
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: profile.maxBitrateBps)
            encoding.minBitrateBps = NSNumber(value: profile.minBitrateBps)
            encoding.maxFramerate = NSNumber(value: profile.framesPerSecond)
            encoding.scaleResolutionDownBy = NSNumber(value: 1.0)
            encoding.bitratePriority = 4.0
        }
        parameters.degradationPreference = Self.maintainResolutionPreference
        sender.parameters = parameters
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
    package nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete {
            resumeIceGatheringWaiters()
        }
    }

    package nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        sendPublisherCandidate(candidate)
    }

    package nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChangeLocalCandidate candidate: RTCIceCandidate) {
        sendPublisherCandidate(candidate)
    }
}

package enum PublisherSessionError: Error, LocalizedError, Equatable {
    case closed
    case h264Unavailable
    case videoTransceiverUnavailable
    case codecPreferencesFailed(String)
    case offerMissing

    package var errorDescription: String? {
        switch self {
        case .closed:
            "Publisher session is closed."
        case .h264Unavailable:
            String(localized: "This Mac's WebRTC stack did not expose H.264 video encoding.")
        case .videoTransceiverUnavailable:
            "WebRTC publisher video transceiver is unavailable."
        case .codecPreferencesFailed(let reason):
            "Failed to set publisher codec preferences: \(reason)"
        case .offerMissing:
            "WebRTC publisher offer is missing."
        }
    }
}
#endif
