import CoreVideo
import Foundation
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Synchronization

package protocol RelayPublisherSessioning: AnyObject, Sendable {
    nonisolated func start() async throws
    nonisolated func updateEncodingProfile(_ profile: WebRTCStreamingProfile)
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

    private nonisolated struct QueuedSignal: Sendable {
        let text: String
        let disconnectAfterSend: Bool
        let coalescingKey: CoalescingKey?
    }

    private nonisolated enum CoalescingKey: Sendable, Equatable {
        case answer
        case stopped
    }

    private nonisolated enum EnqueueDecision {
        case sendNow(QueuedSignal)
        case queued
        case overflow
        case dropped
    }

    private nonisolated struct ClientState {
        nonisolated(unsafe) let connection: any SignalSocketConnection
        let clientID: String
        let sessionEpoch: UInt64
        let target: ShareTarget
        let eventSink: @Sendable (SharingSessionEvent) -> Void
        var nextEventSequence: UInt64 = 0
        var isSending = false
        var pendingSignals: [QueuedSignal] = []
    }

    private nonisolated struct State: ~Copyable {
        var clients: [ObjectIdentifier: ClientState] = [:]
        var nextSessionEpoch: UInt64 = 0
        var onDemandChanged: @Sendable (Bool) -> Void
        var streamingProfile = WebRTCStreamingProfile(performanceMode: .automatic)
        var publisher: (any RelayPublisherSessioning)?
        var publisherTask: Task<Void, Never>?
        var publisherGeneration: UInt64 = 0
        var roomID: String?
    }

    private let state: Mutex<State>
    private let relayClientProvider: RelayClientProvider
    private let publisherFactory: PublisherFactory
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
        publisherFactory: PublisherFactory? = nil
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
        let profile = WebRTCStreamingProfile(performanceMode: mode)
        let publisher = state.withLock { state -> (any RelayPublisherSessioning)? in
            guard state.streamingProfile != profile else { return nil }
            state.streamingProfile = profile
            return state.publisher
        }
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
            guard let payload = state.withLock({ state -> (roomID: String, clientID: String, sessionEpoch: UInt64)? in
                guard let client = state.clients[key] else { return nil }
                return (Self.roomID(for: client.target), client.clientID, client.sessionEpoch)
            }) else {
                return
            }
            emitEvent(phase: .offerReceived, source: .peerConnection, for: key)
            ensurePublisher(roomID: payload.roomID)
            Task { [weak self] in
                await self?.forwardViewerOffer(
                    sdp: sdp,
                    roomID: payload.roomID,
                    clientID: payload.clientID,
                    sessionEpoch: payload.sessionEpoch,
                    key: key
                )
            }
        case .iceCandidate:
            guard let candidate = message.candidate else {
                send(message: SignalingOutboundMessage(type: .error, reason: "missing_ice_candidate"), to: key)
                return
            }
            guard let payload = state.withLock({ state -> (roomID: String, clientID: String, sessionEpoch: UInt64)? in
                guard let client = state.clients[key] else { return nil }
                return (Self.roomID(for: client.target), client.clientID, client.sessionEpoch)
            }) else {
                return
            }
            Task { [weak self, relayClientProvider] in
                do {
                    guard let self,
                          self.isCurrentViewer(
                              key: key,
                              roomID: payload.roomID,
                              clientID: payload.clientID,
                              sessionEpoch: payload.sessionEpoch
                          ) else {
                        return
                    }
                    let client = try await relayClientProvider()
                    guard self.isCurrentViewer(
                        key: key,
                        roomID: payload.roomID,
                        clientID: payload.clientID,
                        sessionEpoch: payload.sessionEpoch
                    ) else {
                        await client.removeViewer(roomID: payload.roomID, clientID: payload.clientID)
                        return
                    }
                    try await client.viewerCandidate(
                        roomID: payload.roomID,
                        clientID: payload.clientID,
                        candidate: candidate,
                        sdpMid: message.sdpMid,
                        sdpMLineIndex: Int32(message.sdpMLineIndex ?? 0)
                    )
                    if !self.isCurrentViewer(
                        key: key,
                        roomID: payload.roomID,
                        clientID: payload.clientID,
                        sessionEpoch: payload.sessionEpoch
                    ) {
                        await client.removeViewer(roomID: payload.roomID, clientID: payload.clientID)
                    }
                } catch {
                    if self?.isCurrentViewer(
                        key: key,
                        roomID: payload.roomID,
                        clientID: payload.clientID,
                        sessionEpoch: payload.sessionEpoch
                    ) == true {
                        AppLog.web.warning("Relay viewer ICE candidate failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        case .iceComplete:
            return
        default:
            send(message: SignalingOutboundMessage(type: .error, reason: "unsupported_signal_type"), to: key)
        }
    }

    private nonisolated func ensurePublisher(roomID: String) {
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
            AppLog.web.info("Starting relay publisher for room \(roomID, privacy: .public).")
        }
    }

    private nonisolated func storeStartedPublisher(
        _ publisher: any RelayPublisherSessioning,
        roomID: String,
        generation: UInt64
    ) {
        let decision = state.withLock { state -> (shouldClose: Bool, profile: WebRTCStreamingProfile?) in
            guard state.publisherGeneration == generation else {
                return (true, nil)
            }
            state.publisherTask = nil
            guard !state.clients.isEmpty, state.roomID == roomID else {
                return (true, nil)
            }
            let profile = state.streamingProfile
            state.publisher = publisher
            return (false, profile)
        }
        if decision.shouldClose {
            publisher.close()
            return
        }
        if let profile = decision.profile {
            publisher.updateEncodingProfile(profile)
        }
        AppLog.web.info("Relay publisher started for room \(roomID, privacy: .public).")
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

    private nonisolated func forwardViewerOffer(
        sdp: String,
        roomID: String,
        clientID: String,
        sessionEpoch: UInt64,
        key: ObjectIdentifier
    ) async {
        do {
            guard isCurrentViewer(key: key, roomID: roomID, clientID: clientID, sessionEpoch: sessionEpoch) else {
                return
            }
            let relayClient = try await relayClientProvider()
            guard isCurrentViewer(key: key, roomID: roomID, clientID: clientID, sessionEpoch: sessionEpoch) else {
                await relayClient.removeViewer(roomID: roomID, clientID: clientID)
                return
            }
            let answer = try await relayClient.viewerOffer(roomID: roomID, clientID: clientID, sdp: sdp)
            guard isCurrentViewer(key: key, roomID: roomID, clientID: clientID, sessionEpoch: sessionEpoch) else {
                await relayClient.removeViewer(roomID: roomID, clientID: clientID)
                return
            }
            send(message: SignalingOutboundMessage(type: .answer, sdp: answer), to: key)
            emitEvent(phase: .peerConnected, source: .peerConnection, for: key)
        } catch {
            guard isCurrentViewer(key: key, roomID: roomID, clientID: clientID, sessionEpoch: sessionEpoch) else {
                return
            }
            AppLog.web.warning("Relay viewer offer failed: \(String(describing: error), privacy: .public)")
            send(message: SignalingOutboundMessage(type: .error, reason: "relay_viewer_offer_failed"), to: key)
            removeClient(for: key, cancelConnection: true)
        }
    }

    private nonisolated func isCurrentViewer(
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

    private nonisolated func send(message: SignalingOutboundMessage, to key: ObjectIdentifier) {
        enqueue(message: message, to: key, disconnectAfterSend: false, replacePending: false)
    }

    private nonisolated func enqueue(
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
        let (removed, shouldSignalDemandOff, callback, roomID) = state.withLock {
            state -> (ClientState?, Bool, @Sendable (Bool) -> Void, String?) in
            let removed = state.clients.removeValue(forKey: key)
            return (removed, state.clients.isEmpty, state.onDemandChanged, state.roomID)
        }

        guard let removed else { return }
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

    private nonisolated func emitEvent(
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

    private nonisolated static func roomID(for target: ShareTarget) -> String {
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
