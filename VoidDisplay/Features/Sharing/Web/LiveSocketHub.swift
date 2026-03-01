import Foundation
import Network
import OSLog
import Synchronization

protocol LiveSocketConnection: AnyObject {
    nonisolated func sendSocketFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void)
    nonisolated func cancelSocket()
}

extension NWConnection: LiveSocketConnection {
    nonisolated func sendSocketFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void) {
        send(content: content, completion: .contentProcessed(completion))
    }

    nonisolated func cancelSocket() {
        cancel()
    }
}

enum LiveControlMessage {
    case config(LiveVideoConfiguration)
    case stopped
}

final class LiveSocketHub: Sendable {
    private struct ClientState {
        nonisolated let connection: any LiveSocketConnection
        var isSending = false
        var pendingFrame: Data?
        var needsConfiguration = true
    }

    private struct State: ~Copyable {
        var clients: [ObjectIdentifier: ClientState] = [:]
        var configuration: LiveVideoConfiguration?
        var onDemandChanged: @Sendable (Bool) -> Void
    }

    nonisolated private let state: Mutex<State>

    nonisolated init(onDemandChanged: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.state = Mutex(State(onDemandChanged: onDemandChanged))
    }

    nonisolated var activeClientCount: Int {
        state.withLock { $0.clients.count }
    }

    nonisolated var hasDemand: Bool {
        activeClientCount > 0
    }

    nonisolated func updateDemandHandler(_ onDemandChanged: @escaping @Sendable (Bool) -> Void) {
        state.withLock { $0.onDemandChanged = onDemandChanged }
    }

    nonisolated func addClient(_ connection: any LiveSocketConnection) {
        let key = ObjectIdentifier(connection as AnyObject)
        let (shouldSignalDemand, callback) = state.withLock { state -> (Bool, @Sendable (Bool) -> Void) in
            let wasEmpty = state.clients.isEmpty
            state.clients[key] = ClientState(connection: connection, needsConfiguration: state.configuration != nil)
            return (wasEmpty, state.onDemandChanged)
        }
        if shouldSignalDemand {
            callback(true)
        }
    }

    nonisolated func removeClient(_ connection: any LiveSocketConnection) {
        removeClient(for: ObjectIdentifier(connection as AnyObject), cancelConnection: false)
    }

    nonisolated func disconnectAllClients() {
        let keys = state.withLock { Array($0.clients.keys) }
        for key in keys {
            removeClient(for: key, cancelConnection: true)
        }
    }

    nonisolated func updateConfiguration(_ configuration: LiveVideoConfiguration) {
        state.withLock { state in
            state.configuration = configuration
            for key in state.clients.keys {
                state.clients[key]?.needsConfiguration = true
            }
        }
    }

    nonisolated func broadcastControl(_ message: LiveControlMessage) {
        switch message {
        case .config(let configuration):
            updateConfiguration(configuration)
        case .stopped:
            let payload = encodeWebSocketTextFrame(#"{"type":"stopped"}"#)
            let keys = state.withLock { Array($0.clients.keys) }
            for key in keys {
                enqueue(payload, to: key)
            }
        }
    }

    nonisolated func broadcast(packet: EncodedVideoPacket) {
        let snapshot: [(ObjectIdentifier, ClientState, LiveVideoConfiguration?)]
        snapshot = state.withLock { state in
            state.clients.map { ($0.key, $0.value, state.configuration) }
        }

        for (key, clientState, configuration) in snapshot {
            var frames: [Data] = []
            if clientState.needsConfiguration {
                guard packet.isKeyframe, let configuration else { continue }
                frames.append(encodeWebSocketTextFrame(makeLiveConfigJSON(configuration)))
                updateNeedsConfiguration(false, for: key)
                frames.append(encodeWebSocketBinaryFrame(encodeLiveVideoPacket(packet: packet, configRefresh: true)))
            } else {
                frames.append(encodeWebSocketBinaryFrame(encodeLiveVideoPacket(packet: packet, configRefresh: false)))
            }

            let payload = frames.reduce(into: Data()) { partialResult, frame in
                partialResult.append(frame)
            }
            enqueue(payload, to: key)
        }
    }

    nonisolated private func updateNeedsConfiguration(_ value: Bool, for key: ObjectIdentifier) {
        state.withLock { $0.clients[key]?.needsConfiguration = value }
    }

    nonisolated private func enqueue(_ frameData: Data, to key: ObjectIdentifier) {
        let shouldSend = state.withLock { state -> Bool in
            guard var current = state.clients[key] else { return false }
            if current.isSending {
                current.pendingFrame = frameData
                state.clients[key] = current
                return false
            } else {
                current.isSending = true
                state.clients[key] = current
                return true
            }
        }

        guard shouldSend else { return }
        send(frameData, to: key)
    }

    nonisolated private func send(_ frameData: Data, to key: ObjectIdentifier) {
        let connection = state.withLock { $0.clients[key]?.connection }
        guard let connection else { return }

        connection.sendSocketFrame(frameData) { [weak self] error in
            guard let self else { return }
            if let error {
                AppErrorMapper.logFailure("Send live socket packet", error: error, logger: AppLog.web)
                self.removeClient(for: key, cancelConnection: true)
                return
            }

            let pending = self.state.withLock { state -> Data? in
                guard var current = state.clients[key] else { return nil }
                let pending = current.pendingFrame
                current.pendingFrame = nil
                current.isSending = pending != nil
                state.clients[key] = current
                return pending
            }

            if let pending {
                self.send(pending, to: key)
            }
        }
    }

    nonisolated private func removeClient(for key: ObjectIdentifier, cancelConnection: Bool) {
        let (removed, shouldSignalDemandOff, callback) = state.withLock { state -> (ClientState?, Bool, @Sendable (Bool) -> Void) in
            let removed = state.clients.removeValue(forKey: key)
            return (removed, state.clients.isEmpty, state.onDemandChanged)
        }

        guard let removed else { return }
        if cancelConnection {
            removed.connection.cancelSocket()
        }
        if shouldSignalDemandOff {
            callback(false)
        }
    }
}
