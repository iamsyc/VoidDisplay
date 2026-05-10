import VoidDisplaySharing
import CoreVideo
import Foundation
import Synchronization
import VoidDisplayFoundation

package final class TestSignalSessionHub: SignalSessionHub, @unchecked Sendable {
    private struct ClientState {
        nonisolated(unsafe) let connection: any SignalSocketConnection
        let clientID: String
        let sessionEpoch: UInt64
        let target: ShareTarget
        let eventSink: @Sendable (SharingSessionEvent) -> Void
        var nextEventSequence: UInt64 = 0
    }

    private struct State: ~Copyable {
        var clients: [ObjectIdentifier: ClientState] = [:]
        var nextSessionEpoch: UInt64 = 0
        var onDemandChanged: @Sendable (Bool) -> Void = { _ in }
    }

    private let state = Mutex(State())

    package init() {}

    package nonisolated var activeClientCount: Int {
        state.withLock { $0.clients.count }
    }

    package nonisolated var hasDemand: Bool {
        activeClientCount > 0
    }

    package nonisolated func updateDemandHandler(_ onDemandChanged: @escaping @Sendable (Bool) -> Void) {
        state.withLock { $0.onDemandChanged = onDemandChanged }
    }

    package nonisolated func addClient(
        _ connection: any SignalSocketConnection,
        target: ShareTarget,
        makeClientID: @escaping @Sendable () -> String = { UUID().uuidString },
        eventSink: @escaping @Sendable (SharingSessionEvent) -> Void
    ) -> SignalSessionClientAddResult {
        let key = ObjectIdentifier(connection as AnyObject)
        let clientID = makeClientID()
        let demandCallback = state.withLock { state -> (@Sendable (Bool) -> Void)? in
            let wasEmpty = state.clients.isEmpty
            state.nextSessionEpoch &+= 1
            state.clients[key] = ClientState(
                connection: connection,
                clientID: clientID,
                sessionEpoch: state.nextSessionEpoch,
                target: target,
                eventSink: eventSink
            )
            return wasEmpty ? state.onDemandChanged : nil
        }
        demandCallback?(true)
        emitEvent(phase: .signalingConnected, source: .webSocket, for: key)
        send(message: SignalingOutboundMessage(type: .ready), to: connection)
        return .accepted(clientID: clientID)
    }

    package nonisolated func removeClient(_ connection: any SignalSocketConnection) {
        removeClient(for: ObjectIdentifier(connection as AnyObject), cancelConnection: false)
    }

    package nonisolated func sendRejection(reason: String, to connection: any SignalSocketConnection) {
        send(message: SignalingOutboundMessage(type: .error, reason: reason), to: connection)
    }

    package nonisolated func disconnectAllClients() {
        for key in state.withLock({ Array($0.clients.keys) }) {
            removeClient(for: key, cancelConnection: true)
        }
    }

    package nonisolated func stopSharing() {
        for key in state.withLock({ Array($0.clients.keys) }) {
            if let connection = state.withLock({ $0.clients[key]?.connection }) {
                send(message: SignalingOutboundMessage(type: .stopped), to: connection)
            }
            removeClient(for: key, cancelConnection: true)
        }
    }

    package nonisolated func updateSourceVideoSpec(_: SourceVideoSpec) {}

    package nonisolated func updatePerformanceMode(_: CapturePerformanceMode) {}

    package nonisolated func receiveSignalText(_ text: String, from connection: any SignalSocketConnection) {
        let key = ObjectIdentifier(connection as AnyObject)
        guard let message = parseMessage(text) else {
            send(message: SignalingOutboundMessage(type: .error, reason: "invalid_signal_payload"), to: connection)
            return
        }
        guard let typeRawValue = message.type else {
            send(message: SignalingOutboundMessage(type: .error, reason: "missing_signal_type"), to: connection)
            return
        }
        guard let type = SignalingMessageType(rawValue: typeRawValue) else {
            send(message: SignalingOutboundMessage(type: .error, reason: "unsupported_signal_type"), to: connection)
            return
        }

        switch type {
        case .viewerReady, .iceComplete:
            return
        case .offer:
            guard message.sdp != nil else {
                send(message: SignalingOutboundMessage(type: .error, reason: "missing_offer_sdp"), to: connection)
                return
            }
            emitEvent(phase: .offerReceived, source: .peerConnection, for: key)
            send(message: SignalingOutboundMessage(type: .answer, sdp: "test-answer"), to: connection)
            emitEvent(phase: .peerConnected, source: .peerConnection, for: key)
        case .iceCandidate:
            guard message.candidate != nil else {
                send(message: SignalingOutboundMessage(type: .error, reason: "missing_ice_candidate"), to: connection)
                return
            }
        default:
            send(message: SignalingOutboundMessage(type: .error, reason: "unsupported_signal_type"), to: connection)
        }
    }

    package nonisolated func submitFrame(pixelBuffer _: CVPixelBuffer, ptsUs _: UInt64) {}

    private nonisolated func removeClient(for key: ObjectIdentifier, cancelConnection: Bool) {
        let result = state.withLock { state -> (
            connection: (any SignalSocketConnection)?,
            event: SharingSessionEvent?,
            sink: (@Sendable (SharingSessionEvent) -> Void)?,
            demandCallback: (@Sendable (Bool) -> Void)?
        ) in
            guard var client = state.clients.removeValue(forKey: key) else {
                return (nil, nil, nil, nil)
            }
            client.nextEventSequence += 1
            let event = SharingSessionEvent(
                target: client.target,
                clientID: client.clientID,
                sessionEpoch: client.sessionEpoch,
                sequence: client.nextEventSequence,
                phase: .closed,
                source: .webSocket
            )
            let demandCallback = state.clients.isEmpty ? state.onDemandChanged : nil
            return (client.connection, event, client.eventSink, demandCallback)
        }
        if let event = result.event, let sink = result.sink {
            sink(event)
        }
        result.demandCallback?(false)
        if cancelConnection {
            result.connection?.cancelSocket()
        }
    }

    private nonisolated func emitEvent(
        phase: SharingPeerPhase,
        source: SharingSessionEventSource,
        for key: ObjectIdentifier
    ) {
        let payload = state.withLock {
            state -> (event: SharingSessionEvent, sink: @Sendable (SharingSessionEvent) -> Void)? in
            guard var client = state.clients[key] else { return nil }
            client.nextEventSequence += 1
            let event = SharingSessionEvent(
                target: client.target,
                clientID: client.clientID,
                sessionEpoch: client.sessionEpoch,
                sequence: client.nextEventSequence,
                phase: phase,
                source: source
            )
            state.clients[key] = client
            return (event, client.eventSink)
        }
        guard let payload else { return }
        payload.sink(payload.event)
    }

    private nonisolated func parseMessage(_ text: String) -> SignalingInboundMessage? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SignalingInboundMessage.self, from: data)
    }

    private nonisolated func send(message: SignalingOutboundMessage, to connection: any SignalSocketConnection) {
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        connection.sendSocketFrame(encodeWebSocketTextFrame(text)) { _ in }
    }
}
