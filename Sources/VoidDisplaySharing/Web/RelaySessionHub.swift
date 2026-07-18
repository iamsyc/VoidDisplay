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

    private nonisolated enum EnqueueDecision {
        case sendNow(QueuedSignal)
        case queued
        case overflow
        case dropped
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
    private let publisherFactory: PublisherFactory
    private let publisherStartupWaitTimeout: Duration
    nonisolated package static let maxClients = 16
    nonisolated package static let maxOffersPerClient = 3
    nonisolated package static let maxOfferSDPBytes = 128 * 1024
    nonisolated package static let maxCandidatesPerClient = 64
    nonisolated package static let maxCandidateBytesPerClient = 128 * 1024
    nonisolated package static let maxCandidateValueBytes = 4 * 1024
    nonisolated private static let maxSDPMidBytes = 256
    nonisolated private static let maxPendingSignalsPerClient = 256

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

    nonisolated func ensurePublisher(roomID: String) {
        let shouldStart = state.withLock { state -> Bool in
            if state.publisher != nil || state.publisherTask != nil {
                return false
            }
            let profile = state.streamingProfile
            state.publisherGeneration &+= 1
            let generation = state.publisherGeneration
            let task = Task { [weak self, relayClientProvider, publisherFactory] in
                do {
                    let relayClient = try await relayClientProvider()
                    guard let publisher = publisherFactory(roomID, relayClient, profile) else {
                        throw RelaySessionHubError.publisherUnavailable
                    }
                    try await publisher.start()
                    self?.storeStartedPublisher(publisher, roomID: roomID, generation: generation)
                } catch {
                    self?.handlePublisherStartupFailure(error, generation: generation)
                }
            }
            state.publisherTask = task
            return true
        }
        if shouldStart {
            AppLog.web.info("Starting relay publisher for room \(roomID, privacy: .private(mask: .hash)).")
        }
    }

    private nonisolated func storeStartedPublisher(
        _ publisher: any RelayPublisherSessioning,
        roomID: String,
        generation: UInt64
    ) {
        let decision = state.withLock {
            state -> (shouldClose: Bool, profile: WebRTCStreamingProfile?, activeCodecs: Set<WebRTCVideoCodec>) in
            guard state.publisherGeneration == generation else {
                return (true, nil, [])
            }
            state.publisherTask = nil
            guard !state.clients.isEmpty, state.roomID == roomID else {
                return (true, nil, [])
            }
            let profile = state.streamingProfile
            let activeCodecs = Self.activeCodecs(from: state.clients)
            state.publisher = publisher
            return (false, profile, activeCodecs)
        }
        if decision.shouldClose {
            publisher.close()
            return
        }
        if let profile = decision.profile {
            publisher.updateEncodingProfile(profile)
            publisher.updateActiveCodecs(decision.activeCodecs)
        }
        AppLog.web.info("Relay publisher started for room \(roomID, privacy: .private(mask: .hash)).")
    }

    private nonisolated func handlePublisherStartupFailure(_ error: any Error, generation: UInt64) {
        let keys = state.withLock { state -> [ObjectIdentifier] in
            guard state.publisherGeneration == generation else {
                return []
            }
            state.publisherTask = nil
            return Array(state.clients.keys)
        }
        guard !keys.isEmpty else { return }
        AppLog.web.error("Relay publisher startup failed: \(String(describing: error), privacy: .public)")
        for key in keys {
            send(message: SignalingOutboundMessage(type: .error, reason: "relay_publisher_unavailable"), to: key)
            removeClient(for: key, cancelConnection: true)
        }
    }

    nonisolated func waitForPublisherStartup(roomID: String) async -> PublisherStartupWaitResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: publisherStartupWaitTimeout)
        while true {
            let waitResult = state.withLock { state -> PublisherStartupWaitResult? in
                guard state.roomID == roomID else { return .failed }
                if state.publisher != nil {
                    return .ready
                }
                guard state.publisherTask != nil else {
                    return .failed
                }
                return nil
            }
            if let waitResult {
                return waitResult
            }
            if clock.now >= deadline {
                return .timedOut
            }
            if Task.isCancelled {
                return .failed
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return .failed
            }
        }
    }

    nonisolated func isCurrentViewer(
        key: ObjectIdentifier,
        roomID: String,
        clientID: String,
        sessionEpoch: UInt64
    ) -> Bool {
        state.withLock { state -> Bool in
            guard let client = state.clients[key] else { return false }
            return client.clientID == clientID
                && client.sessionEpoch == sessionEpoch
                && Self.roomID(for: client.target) == roomID
        }
    }

    private nonisolated func stopPublisherIfIdle(force: Bool) {
        let publisher = state.withLock { state -> (any RelayPublisherSessioning)? in
            guard force || state.clients.isEmpty else { return nil }
            state.publisherGeneration &+= 1
            let publisher = state.publisher
            state.publisher = nil
            state.publisherTask?.cancel()
            state.publisherTask = nil
            return publisher
        }
        publisher?.close()
    }

    private nonisolated func parseMessage(_ text: String) -> SignalingInboundMessage? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SignalingInboundMessage.self, from: data)
    }

    private nonisolated func encode(_ message: SignalingOutboundMessage) -> String? {
        guard let data = try? JSONEncoder().encode(message) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated func send(
        message: SignalingOutboundMessage,
        to connection: any SignalSocketConnection,
        completion: (@Sendable (Error?) -> Void)?
    ) {
        guard let text = encode(message) else {
            completion?(nil)
            return
        }
        connection.sendSocketFrame(encodeWebSocketTextFrame(text)) { error in
            completion?(error)
        }
    }

    nonisolated func send(message: SignalingOutboundMessage, to key: ObjectIdentifier) {
        enqueue(message: message, to: key, disconnectAfterSend: false, replacePending: false)
    }

    nonisolated func enqueue(
        message: SignalingOutboundMessage,
        to key: ObjectIdentifier,
        disconnectAfterSend: Bool,
        replacePending: Bool
    ) {
        guard let text = encode(message) else {
            if disconnectAfterSend {
                removeClient(for: key, cancelConnection: true)
            }
            return
        }
        let coalescingKey = coalescingKey(for: message)
        let connection = state.withLock { $0.clients[key]?.connection }
        guard let connection else { return }
        enqueue(
            text: text,
            to: key,
            connection: connection,
            disconnectAfterSend: disconnectAfterSend,
            replacePending: replacePending,
            coalescingKey: coalescingKey
        )
    }

    private nonisolated func enqueue(
        text: String,
        to key: ObjectIdentifier,
        connection: any SignalSocketConnection,
        disconnectAfterSend: Bool,
        replacePending: Bool,
        coalescingKey: CoalescingKey?
    ) {
        let queuedSignal = QueuedSignal(
            text: text,
            disconnectAfterSend: disconnectAfterSend,
            coalescingKey: coalescingKey
        )
        let decision = state.withLock { state -> EnqueueDecision in
            guard var current = state.clients[key] else { return .dropped }
            if current.isSending {
                if replacePending {
                    current.pendingSignals = [queuedSignal]
                    state.clients[key] = current
                    return .queued
                }
                if let coalescingKey,
                   let index = current.pendingSignals.lastIndex(where: { $0.coalescingKey == coalescingKey }) {
                    current.pendingSignals[index] = queuedSignal
                    state.clients[key] = current
                    return .queued
                }
                if current.pendingSignals.count >= Self.maxPendingSignalsPerClient {
                    return .overflow
                }
                current.pendingSignals.append(queuedSignal)
                state.clients[key] = current
                return .queued
            }
            current.isSending = true
            state.clients[key] = current
            return .sendNow(queuedSignal)
        }

        switch decision {
        case .sendNow(let nextToSend):
            send(signal: nextToSend, to: key, connection: connection)
        case .queued:
            return
        case .overflow:
            AppLog.web.warning("Relay signaling backlog overflow; disconnecting client.")
            removeClient(for: key, cancelConnection: true)
        case .dropped:
            return
        }
    }

    private nonisolated func coalescingKey(for message: SignalingOutboundMessage) -> CoalescingKey? {
        switch message.type {
        case .answer:
            return .answer
        case .stopped:
            return .stopped
        default:
            return nil
        }
    }

    private nonisolated func send(
        signal: QueuedSignal,
        to key: ObjectIdentifier,
        connection: any SignalSocketConnection
    ) {
        connection.sendSocketFrame(encodeWebSocketTextFrame(signal.text)) { [weak self] error in
            guard let self else { return }
            if let error {
                AppErrorMapper.logFailure("Send relay signaling message", error: error, logger: AppLog.web)
                self.removeClient(for: key, cancelConnection: true)
                return
            }
            if signal.disconnectAfterSend {
                self.removeClient(for: key, cancelConnection: true)
                return
            }
            let nextSignal = self.state.withLock { state -> QueuedSignal? in
                guard var current = state.clients[key] else { return nil }
                if current.pendingSignals.isEmpty {
                    current.isSending = false
                    state.clients[key] = current
                    return nil
                }
                let pending = current.pendingSignals.removeFirst()
                state.clients[key] = current
                return pending
            }
            guard let nextSignal else { return }
            guard let nextConnection = self.state.withLock({ $0.clients[key]?.connection }) else { return }
            self.send(signal: nextSignal, to: key, connection: nextConnection)
        }
    }

    private nonisolated func removeClient(for key: ObjectIdentifier, cancelConnection: Bool) {
        let (removed, shouldSignalDemandOff, callback, roomID, publisher, activeCodecs) = state.withLock {
            state -> (
                ClientState?,
                Bool,
                @Sendable (Bool) -> Void,
                String?,
                (any RelayPublisherSessioning)?,
                Set<WebRTCVideoCodec>
            ) in
            let removed = state.clients.removeValue(forKey: key)
            return (
                removed,
                state.clients.isEmpty,
                state.onDemandChanged,
                state.roomID,
                state.publisher,
                Self.activeCodecs(from: state.clients)
            )
        }

        guard let removed else { return }
        removed.offerTask?.cancel()
        removed.candidateDrainTask?.cancel()
        publisher?.updateActiveCodecs(activeCodecs)
        removed.eventSink(
            SharingSessionEvent(
                target: removed.target,
                clientID: removed.clientID,
                sessionEpoch: removed.sessionEpoch,
                sequence: removed.nextEventSequence + 1,
                phase: .closed,
                source: .webSocket
            )
        )
        if let roomID {
            Task { [relayClientProvider, clientID = removed.clientID] in
                if let relayClient = try? await relayClientProvider() {
                    await relayClient.removeViewer(roomID: roomID, clientID: clientID)
                }
            }
        }
        if cancelConnection {
            removed.connection.cancelSocket()
        }
        if shouldSignalDemandOff {
            callback(false)
            stopPublisherIfIdle(force: false)
        }
    }

    private nonisolated func emitEvent(_ event: SharingSessionEvent, for key: ObjectIdentifier) {
        let sink = state.withLock { $0.clients[key]?.eventSink }
        sink?(event)
    }

    nonisolated func emitEvent(
        phase: SharingPeerPhase,
        source: SharingSessionEventSource,
        for key: ObjectIdentifier
    ) {
        let payload = state.withLock {
            state -> (target: ShareTarget, clientID: String, sessionEpoch: UInt64, sequence: UInt64, sink: @Sendable (SharingSessionEvent) -> Void)? in
            guard var client = state.clients[key] else { return nil }
            client.nextEventSequence += 1
            let sequence = client.nextEventSequence
            state.clients[key] = client
            return (client.target, client.clientID, client.sessionEpoch, sequence, client.eventSink)
        }
        guard let payload else { return }
        payload.sink(
            SharingSessionEvent(
                target: payload.target,
                clientID: payload.clientID,
                sessionEpoch: payload.sessionEpoch,
                sequence: payload.sequence,
                phase: phase,
                source: source
            )
        )
    }

    private nonisolated func nextEventSequence(for key: ObjectIdentifier) -> UInt64 {
        state.withLock { state -> UInt64 in
            guard var client = state.clients[key] else { return 0 }
            client.nextEventSequence += 1
            let sequence = client.nextEventSequence
            state.clients[key] = client
            return sequence
        }
    }

    nonisolated static func activeCodecs(from clients: [ObjectIdentifier: ClientState]) -> Set<WebRTCVideoCodec> {
        Set(clients.values.compactMap(\.selectedCodec))
    }

    nonisolated static func roomID(for target: ShareTarget) -> String {
        switch target {
        case .main:
            return "main"
        case .id(let id):
            return String(id)
        }
    }
}

package enum RelaySessionHubError: Error, Equatable {
    case publisherUnavailable
}
