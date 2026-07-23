import CoreVideo
import Foundation
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Synchronization

extension RelaySessionHub {
    private nonisolated enum EnqueueDecision {
        case sendNow(QueuedSignal)
        case queued
        case overflow
        case dropped
    }

    private nonisolated static let maxPendingSignalsPerClient = 256

    nonisolated func parseMessage(_ text: String) -> SignalingInboundMessage? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SignalingInboundMessage.self, from: data)
    }

    private nonisolated func encode(_ message: SignalingOutboundMessage) -> String? {
        guard let data = try? JSONEncoder().encode(message) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated func send(
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

    nonisolated func removeClient(for key: ObjectIdentifier, cancelConnection: Bool) {
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

    nonisolated func emitEvent(_ event: SharingSessionEvent, for key: ObjectIdentifier) {
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

    nonisolated func nextEventSequence(for key: ObjectIdentifier) -> UInt64 {
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
