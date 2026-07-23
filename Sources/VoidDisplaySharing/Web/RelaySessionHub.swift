import CoreVideo
import Foundation
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Synchronization

package protocol RelayPublisherSessioning: AnyObject, Sendable {
    nonisolated func start() async throws
    nonisolated func updateEncodingProfile(_ profile: WebRTCStreamingProfile)
    nonisolated func updateActiveCodecs(_ activeCodecs: Set<WebRTCVideoCodec>)
    nonisolated func submitFrame(pixelBuffer: CVPixelBuffer, ptsUs: UInt64)
    nonisolated func close()
}

#if canImport(WebRTC)
extension WebRTCPublisherSession: RelayPublisherSessioning {}
#endif

package final class RelaySessionHub: Sendable, SignalSessionHub {
    package typealias RelayClientProvider = @Sendable () async throws -> any RelayHTTPClienting
    package typealias PublisherFactory = @Sendable (
        _ roomID: String,
        _ relayClient: any RelayHTTPClienting,
        _ profile: WebRTCStreamingProfile
    ) -> (any RelayPublisherSessioning)?

    nonisolated struct QueuedSignal: Sendable {
        let text: String
        let disconnectAfterSend: Bool
        let coalescingKey: CoalescingKey?
    }

    nonisolated enum CoalescingKey: Sendable, Equatable {
        case answer
        case stopped
    }

    nonisolated enum PublisherStartupWaitResult {
        case ready
        case timedOut
        case failed
    }

    nonisolated enum NegotiationPhase: Equatable {
        case awaitingOffer
        case offerInFlight
        case established
    }

    nonisolated struct PendingViewerCandidate: Sendable {
        let candidate: String
        let sdpMid: String?
        let sdpMLineIndex: Int32
    }

    private nonisolated enum InboundOfferDecision {
        case start(roomID: String, clientID: String, sessionEpoch: UInt64)
        case reject(reason: String)
        case dropped
    }

    private nonisolated enum InboundCandidateDecision {
        case queued(roomID: String, clientID: String, sessionEpoch: UInt64, shouldStartDrain: Bool)
        case reject(reason: String)
        case dropped
    }

    nonisolated struct ClientState {
        nonisolated(unsafe) let connection: any SignalSocketConnection
        let clientID: String
        let sessionEpoch: UInt64
        let target: ShareTarget
        let eventSink: @Sendable (SharingSessionEvent) -> Void
        var selectedCodec: WebRTCVideoCodec?
        var nextEventSequence: UInt64 = 0
        var isSending = false
        var pendingSignals: [QueuedSignal] = []
        var negotiationPhase: NegotiationPhase = .awaitingOffer
        var offerCount = 0
        var offerTask: Task<Void, Never>?
        var pendingViewerCandidates: [PendingViewerCandidate] = []
        var acceptedCandidateCount = 0
        var acceptedCandidateBytes = 0
        var isCandidateDrainRunning = false
        var candidateDrainTask: Task<Void, Never>?
    }

    nonisolated struct State: ~Copyable {
        var clients: [ObjectIdentifier: ClientState] = [:]
        var nextSessionEpoch: UInt64 = 0
        var onDemandChanged: @Sendable (Bool) -> Void
        var performanceMode: CapturePerformanceMode = .automatic
        var sourceVideoSpec: SourceVideoSpec = .defaultShared
        var streamingProfile = WebRTCStreamingProfile(performanceMode: .automatic, sourceVideoSpec: .defaultShared)
        var publisher: (any RelayPublisherSessioning)?
        var publisherTask: Task<Void, Never>?
        var publisherGeneration: UInt64 = 0
        var roomID: String?
    }

    let state: Mutex<State>
    let relayClientProvider: RelayClientProvider
    let publisherFactory: PublisherFactory
    let publisherStartupWaitTimeout: Duration
    nonisolated package static let maxClients = 16
    nonisolated package static let maxOffersPerClient = 3
    nonisolated package static let maxOfferSDPBytes = 128 * 1024
    nonisolated package static let maxCandidatesPerClient = 64
    nonisolated package static let maxCandidateBytesPerClient = 128 * 1024
    nonisolated package static let maxCandidateValueBytes = 4 * 1024
    nonisolated private static let maxSDPMidBytes = 256
#if canImport(WebRTC)
    private let mediaPipeline = WebRTCMediaPipeline()
#endif

    package convenience init(relayProcessController: RelayProcessController) {
        self.init(relayClientProvider: {
            try await relayProcessController.client()
        })
    }

    package init(
        onDemandChanged: @escaping @Sendable (Bool) -> Void = { _ in },
        relayClientProvider: @escaping RelayClientProvider,
        publisherFactory: PublisherFactory? = nil,
        publisherStartupWaitTimeout: Duration = .seconds(2)
    ) {
        self.state = Mutex(State(onDemandChanged: onDemandChanged))
#if canImport(WebRTC)
        let defaultPublisherFactory: PublisherFactory = { [mediaPipeline] roomID, relayClient, profile in
            WebRTCPublisherSession(
                roomID: roomID,
                relayClient: relayClient,
                mediaPipeline: mediaPipeline,
                initialProfile: profile
            )
        }
        self.publisherFactory = publisherFactory ?? defaultPublisherFactory
#else
        self.publisherFactory = publisherFactory ?? { _, _, _ in nil }
#endif
        self.relayClientProvider = relayClientProvider
        self.publisherStartupWaitTimeout = publisherStartupWaitTimeout
    }

    package nonisolated var activeClientCount: Int {
        state.withLock { $0.clients.count }
    }

    package nonisolated var hasDemand: Bool {
        activeClientCount > 0
    }

    package nonisolated func updateDemandHandler(_ onDemandChanged: @escaping @Sendable (Bool) -> Void) {
        state.withLock { $0.onDemandChanged = onDemandChanged }
    }

    package nonisolated func updatePerformanceMode(_ mode: CapturePerformanceMode) {
        let (publisher, profile) = state.withLock { state -> ((any RelayPublisherSessioning)?, WebRTCStreamingProfile?) in
            let profile = WebRTCStreamingProfile(performanceMode: mode, sourceVideoSpec: state.sourceVideoSpec)
            guard state.streamingProfile != profile else { return (nil, nil) }
            state.performanceMode = mode
            state.streamingProfile = profile
            return (state.publisher, profile)
        }
        guard let profile else { return }
        publisher?.updateEncodingProfile(profile)
    }

    package nonisolated func updateSourceVideoSpec(_ spec: SourceVideoSpec) {
        let (publisher, profile) = state.withLock { state -> ((any RelayPublisherSessioning)?, WebRTCStreamingProfile?) in
            guard state.sourceVideoSpec != spec else { return (nil, nil) }
            state.sourceVideoSpec = spec
            let profile = WebRTCStreamingProfile(
                performanceMode: state.performanceMode,
                sourceVideoSpec: spec
            )
            state.streamingProfile = profile
            return (state.publisher, profile)
        }
        guard let profile else { return }
        publisher?.updateEncodingProfile(profile)
    }

    package nonisolated func addClient(
        _ connection: any SignalSocketConnection,
        target: ShareTarget,
        makeClientID: @escaping @Sendable () -> String = { UUID().uuidString },
        eventSink: @escaping @Sendable (SharingSessionEvent) -> Void
    ) -> SignalSessionClientAddResult {
        let roomID = Self.roomID(for: target)
        let key = ObjectIdentifier(connection as AnyObject)
        let (result, acceptedClientID, shouldSignalDemand, callback) = state.withLock {
            state -> (SignalSessionClientAddResult, String?, Bool, @Sendable (Bool) -> Void) in
            guard state.clients[key] == nil else {
                return (.rejected(reason: "duplicate_signal_client"), nil, false, state.onDemandChanged)
            }
            guard state.clients.count < Self.maxClients else {
                return (.rejected(reason: "signal_client_limit_reached"), nil, false, state.onDemandChanged)
            }
            let wasEmpty = state.clients.isEmpty
            let clientID = makeClientID()
            state.nextSessionEpoch &+= 1
            state.roomID = roomID
            state.clients[key] = ClientState(
                connection: connection,
                clientID: clientID,
                sessionEpoch: state.nextSessionEpoch,
                target: target,
                eventSink: eventSink
            )
            return (.accepted(clientID: clientID), clientID, wasEmpty, state.onDemandChanged)
        }
        guard case .accepted = result, let clientID = acceptedClientID else {
            return result
        }

        if shouldSignalDemand {
            callback(true)
        }

        let sessionEpoch = state.withLock { $0.clients[key]?.sessionEpoch } ?? 0
        emitEvent(
            SharingSessionEvent(
                target: target,
                clientID: clientID,
                sessionEpoch: sessionEpoch,
                sequence: nextEventSequence(for: key),
                phase: .signalingConnected,
                source: .webSocket
            ),
            for: key
        )
        send(message: SignalingOutboundMessage(type: .ready), to: connection, completion: nil)
        ensurePublisher(roomID: roomID)
        return .accepted(clientID: clientID)
    }

    package nonisolated func removeClient(_ connection: any SignalSocketConnection) {
        removeClient(for: ObjectIdentifier(connection as AnyObject), cancelConnection: false)
    }

    package nonisolated func sendRejection(reason: String, to connection: any SignalSocketConnection) {
        send(message: SignalingOutboundMessage(type: .error, reason: reason), to: connection, completion: nil)
    }

    package nonisolated func disconnectAllClients() {
        let keys = state.withLock { Array($0.clients.keys) }
        for key in keys {
            removeClient(for: key, cancelConnection: true)
        }
    }

    package nonisolated func stopSharing() {
        let keys = state.withLock { Array($0.clients.keys) }
        for key in keys {
            enqueue(
                message: SignalingOutboundMessage(type: .stopped),
                to: key,
                disconnectAfterSend: true,
                replacePending: true
            )
        }
        stopPublisherIfIdle(force: true)
    }

    package nonisolated func receiveSignalText(_ text: String, from connection: any SignalSocketConnection) {
        let key = ObjectIdentifier(connection as AnyObject)
        guard let message = parseMessage(text) else {
            send(message: SignalingOutboundMessage(type: .error, reason: "invalid_signal_payload"), to: key)
            return
        }
        guard let typeRawValue = message.type else {
            send(message: SignalingOutboundMessage(type: .error, reason: "missing_signal_type"), to: key)
            return
        }
        guard let type = SignalingMessageType(rawValue: typeRawValue) else {
            send(message: SignalingOutboundMessage(type: .error, reason: "unsupported_signal_type"), to: key)
            return
        }
        handle(message: message, type: type, for: key)
    }

    package nonisolated func submitFrame(pixelBuffer: CVPixelBuffer, ptsUs: UInt64) {
        guard hasDemand else { return }
        let publisher = state.withLock { $0.publisher }
        publisher?.submitFrame(pixelBuffer: pixelBuffer, ptsUs: ptsUs)
    }

    private nonisolated func handle(
        message: SignalingInboundMessage,
        type: SignalingMessageType,
        for key: ObjectIdentifier
    ) {
        switch type {
        case .viewerReady:
            return
        case .offer:
            guard let sdp = message.sdp else {
                send(message: SignalingOutboundMessage(type: .error, reason: "missing_offer_sdp"), to: key)
                return
            }
            guard !sdp.isEmpty, sdp.utf8.count <= Self.maxOfferSDPBytes else {
                rejectInboundSignal(reason: "offer_size_limit_exceeded", to: key)
                return
            }
            let decision = state.withLock { state -> InboundOfferDecision in
                guard var client = state.clients[key] else { return .dropped }
                guard client.negotiationPhase == .awaitingOffer else {
                    return .reject(reason: "offer_already_in_progress")
                }
                guard client.offerCount < Self.maxOffersPerClient else {
                    return .reject(reason: "offer_limit_exceeded")
                }
                client.negotiationPhase = .offerInFlight
                client.offerCount += 1
                state.clients[key] = client
                return .start(
                    roomID: Self.roomID(for: client.target),
                    clientID: client.clientID,
                    sessionEpoch: client.sessionEpoch
                )
            }
            switch decision {
            case .start(let roomID, let clientID, let sessionEpoch):
                emitEvent(phase: .offerReceived, source: .peerConnection, for: key)
                ensurePublisher(roomID: roomID)
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.forwardViewerOffer(
                        sdp: sdp,
                        roomID: roomID,
                        clientID: clientID,
                        sessionEpoch: sessionEpoch,
                        key: key
                    )
                }
                storeOfferTask(
                    task,
                    key: key,
                    clientID: clientID,
                    sessionEpoch: sessionEpoch
                )
            case .reject(let reason):
                rejectInboundSignal(reason: reason, to: key)
            case .dropped:
                return
            }
        case .iceCandidate:
            guard let candidate = message.candidate else {
                send(message: SignalingOutboundMessage(type: .error, reason: "missing_ice_candidate"), to: key)
                return
            }
            guard !candidate.isEmpty,
                  candidate.utf8.count <= Self.maxCandidateValueBytes,
                  (message.sdpMid?.utf8.count ?? 0) <= Self.maxSDPMidBytes,
                  let sdpMLineIndex = Int32(exactly: message.sdpMLineIndex ?? 0),
                  sdpMLineIndex >= 0 else {
                rejectInboundSignal(reason: "candidate_value_limit_exceeded", to: key)
                return
            }
            let pendingCandidate = PendingViewerCandidate(
                candidate: candidate,
                sdpMid: message.sdpMid,
                sdpMLineIndex: sdpMLineIndex
            )
            let candidateBytes = candidate.utf8.count + (message.sdpMid?.utf8.count ?? 0)
            let decision = state.withLock { state -> InboundCandidateDecision in
                guard var client = state.clients[key] else { return .dropped }
                guard client.acceptedCandidateCount < Self.maxCandidatesPerClient,
                      client.acceptedCandidateBytes + candidateBytes <= Self.maxCandidateBytesPerClient else {
                    return .reject(reason: "candidate_budget_exceeded")
                }
                client.acceptedCandidateCount += 1
                client.acceptedCandidateBytes += candidateBytes
                client.pendingViewerCandidates.append(pendingCandidate)
                let shouldStartDrain = client.negotiationPhase == .established
                    && !client.isCandidateDrainRunning
                if shouldStartDrain {
                    client.isCandidateDrainRunning = true
                }
                state.clients[key] = client
                return .queued(
                    roomID: Self.roomID(for: client.target),
                    clientID: client.clientID,
                    sessionEpoch: client.sessionEpoch,
                    shouldStartDrain: shouldStartDrain
                )
            }
            switch decision {
            case .queued(let roomID, let clientID, let sessionEpoch, let shouldStartDrain):
                if shouldStartDrain {
                    launchCandidateDrain(
                        key: key,
                        roomID: roomID,
                        clientID: clientID,
                        sessionEpoch: sessionEpoch
                    )
                }
            case .reject(let reason):
                rejectInboundSignal(reason: reason, to: key)
            case .dropped:
                return
            }
        case .iceComplete:
            return
        default:
            send(message: SignalingOutboundMessage(type: .error, reason: "unsupported_signal_type"), to: key)
        }
    }
}

package enum RelaySessionHubError: Error, Equatable {
    case publisherUnavailable
}
