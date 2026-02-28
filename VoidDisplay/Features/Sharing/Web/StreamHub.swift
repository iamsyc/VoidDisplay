import Foundation
import Network
import OSLog

protocol LiveSocketConnection: AnyObject {
    func sendSocketFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void)
    func cancelSocket()
}

extension NWConnection: LiveSocketConnection {
    func sendSocketFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void) {
        send(content: content, completion: .contentProcessed(completion))
    }

    func cancelSocket() {
        cancel()
    }
}

enum LiveControlMessage {
    case config(LiveVideoConfiguration)
    case stopped
}

final class LiveSocketHub: @unchecked Sendable {
    private struct ClientState {
        let connection: any LiveSocketConnection
        var isSending = false
        var pendingFrame: Data?
        var needsConfiguration = true
    }

    private let lock = NSLock()
    private var clients: [ObjectIdentifier: ClientState] = [:]
    private var configuration: LiveVideoConfiguration?
    private var onDemandChanged: @Sendable (Bool) -> Void

    init(onDemandChanged: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.onDemandChanged = onDemandChanged
    }

    var activeClientCount: Int {
        lock.lock()
        let count = clients.count
        lock.unlock()
        return count
    }

    var hasDemand: Bool {
        activeClientCount > 0
    }

    func updateDemandHandler(_ onDemandChanged: @escaping @Sendable (Bool) -> Void) {
        self.onDemandChanged = onDemandChanged
    }

    func addClient(_ connection: any LiveSocketConnection) {
        let key = ObjectIdentifier(connection as AnyObject)
        var shouldSignalDemand = false
        lock.lock()
        shouldSignalDemand = clients.isEmpty
        clients[key] = ClientState(connection: connection, needsConfiguration: configuration != nil)
        lock.unlock()
        if shouldSignalDemand {
            onDemandChanged(true)
        }
    }

    func removeClient(_ connection: any LiveSocketConnection) {
        removeClient(for: ObjectIdentifier(connection as AnyObject), cancelConnection: false)
    }

    func disconnectAllClients() {
        let keys: [ObjectIdentifier]
        lock.lock()
        keys = Array(clients.keys)
        lock.unlock()
        for key in keys {
            removeClient(for: key, cancelConnection: true)
        }
    }

    func updateConfiguration(_ configuration: LiveVideoConfiguration) {
        lock.lock()
        self.configuration = configuration
        for key in clients.keys {
            clients[key]?.needsConfiguration = true
        }
        lock.unlock()
    }

    func broadcastControl(_ message: LiveControlMessage) {
        switch message {
        case .config(let configuration):
            updateConfiguration(configuration)
        case .stopped:
            let payload = makeWebSocketTextFrame(#"{"type":"stopped"}"#)
            let keys: [ObjectIdentifier]
            lock.lock()
            keys = Array(clients.keys)
            lock.unlock()
            for key in keys {
                enqueue(payload, to: key)
            }
        }
    }

    func broadcast(packet: EncodedVideoPacket) {
        let snapshot: [(ObjectIdentifier, ClientState, LiveVideoConfiguration?)]
        lock.lock()
        snapshot = clients.map { ($0.key, $0.value, configuration) }
        lock.unlock()

        for (key, state, configuration) in snapshot {
            var frames: [Data] = []
            if state.needsConfiguration {
                guard packet.isKeyframe, let configuration else { continue }
                frames.append(makeWebSocketTextFrame(makeConfigJSON(configuration)))
                updateNeedsConfiguration(false, for: key)
                frames.append(makeWebSocketBinaryFrame(makeLiveVideoPacket(packet: packet, configRefresh: true)))
            } else {
                frames.append(makeWebSocketBinaryFrame(makeLiveVideoPacket(packet: packet, configRefresh: false)))
            }

            let payload = frames.reduce(into: Data()) { partialResult, frame in
                partialResult.append(frame)
            }
            enqueue(payload, to: key)
        }
    }

    private func makeConfigJSON(_ configuration: LiveVideoConfiguration) -> String {
        #"{"type":"config","codec":"\#(configuration.codec)","width":\#(configuration.width),"height":\#(configuration.height),"timescale":\#(configuration.timescale)}"#
    }

    private func updateNeedsConfiguration(_ value: Bool, for key: ObjectIdentifier) {
        lock.lock()
        clients[key]?.needsConfiguration = value
        lock.unlock()
    }

    private func enqueue(_ frameData: Data, to key: ObjectIdentifier) {
        var state: ClientState?
        lock.lock()
        if var current = clients[key] {
            if current.isSending {
                current.pendingFrame = frameData
                clients[key] = current
            } else {
                current.isSending = true
                clients[key] = current
                state = current
            }
        }
        lock.unlock()

        guard state != nil else { return }
        send(frameData, to: key)
    }

    private func send(_ frameData: Data, to key: ObjectIdentifier) {
        lock.lock()
        guard let state = clients[key] else {
            lock.unlock()
            return
        }
        lock.unlock()

        state.connection.sendSocketFrame(frameData) { [weak self] error in
            guard let self else { return }
            if let error {
                AppErrorMapper.logFailure("Send live socket packet", error: error, logger: AppLog.web)
                self.removeClient(for: key, cancelConnection: true)
                return
            }

            var pending: Data?
            self.lock.lock()
            guard var current = self.clients[key] else {
                self.lock.unlock()
                return
            }
            pending = current.pendingFrame
            current.pendingFrame = nil
            current.isSending = pending != nil
            self.clients[key] = current
            self.lock.unlock()

            if let pending {
                self.send(pending, to: key)
            }
        }
    }

    private func removeClient(for key: ObjectIdentifier, cancelConnection: Bool) {
        let removed: ClientState?
        let shouldSignalDemandOff: Bool
        lock.lock()
        removed = clients.removeValue(forKey: key)
        shouldSignalDemandOff = clients.isEmpty
        lock.unlock()

        guard let removed else { return }
        if cancelConnection {
            removed.connection.cancelSocket()
        }
        if shouldSignalDemandOff {
            onDemandChanged(false)
        }
    }
}
