import Foundation
import Network
import OSLog

protocol StreamClientConnection: AnyObject {
    func sendFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void)
    func cancelStream()
}

extension NWConnection: StreamClientConnection {
    func sendFrame(_ content: Data, completion: @escaping @Sendable (Error?) -> Void) {
        send(content: content, completion: .contentProcessed(completion))
    }

    func cancelStream() {
        cancel()
    }
}

@MainActor
final class StreamHub {
    private struct ClientState {
        let connection: any StreamClientConnection
        var isSending = false
        var pendingFrame: Data?
    }

    private var clients: [ObjectIdentifier: ClientState] = [:]
    private var timer: DispatchSourceTimer?
    private let isSharingProvider: @MainActor @Sendable () -> Bool
    private let frameProvider: @MainActor @Sendable () -> Data?
    private let onSendError: @MainActor (Error) -> Void
    private let frameInterval: DispatchTimeInterval = .milliseconds(100)
    private let automaticallyStartTimer: Bool

    init(
        isSharingProvider: @escaping @MainActor @Sendable () -> Bool,
        frameProvider: @escaping @MainActor @Sendable () -> Data?,
        automaticallyStartTimer: Bool = true,
        onSendError: @escaping @MainActor (Error) -> Void
    ) {
        self.isSharingProvider = isSharingProvider
        self.frameProvider = frameProvider
        self.automaticallyStartTimer = automaticallyStartTimer
        self.onSendError = onSendError
    }

    func addClient(_ connection: any StreamClientConnection) {
        let key = key(for: connection)
        clients[key] = ClientState(connection: connection)
        AppLog.web.debug("StreamHub: added client, active=\(self.clients.count)")
        if automaticallyStartTimer {
            startTimerIfNeeded()
        }
    }

    func removeClient(_ connection: any StreamClientConnection) {
        removeClient(for: key(for: connection), cancelConnection: false)
    }

    func disconnectAllClients() {
        let keys = Array(clients.keys)
        for key in keys {
            removeClient(for: key, cancelConnection: true)
        }
        stopTimer()
    }

    func pumpOnceForTesting() {
        tick()
    }

    var activeClientCountForTesting: Int {
        clients.count
    }

    var activeClientCount: Int {
        clients.count
    }

    private func key(for connection: any StreamClientConnection) -> ObjectIdentifier {
        ObjectIdentifier(connection as AnyObject)
    }

    private func removeClient(for key: ObjectIdentifier, cancelConnection: Bool) {
        guard let removed = clients.removeValue(forKey: key) else { return }
        if cancelConnection {
            removed.connection.cancelStream()
        }
        AppLog.web.debug("StreamHub: removed client, active=\(self.clients.count)")
        if clients.isEmpty {
            stopTimer()
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: frameInterval)
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = source
        source.resume()
        AppLog.web.debug("StreamHub: timer started")
    }

    private func stopTimer() {
        guard let activeTimer = timer else { return }
        activeTimer.setEventHandler {}
        activeTimer.cancel()
        timer = nil
        AppLog.web.debug("StreamHub: timer stopped")
    }

    private func tick() {
        guard !clients.isEmpty else {
            stopTimer()
            return
        }

        guard isSharingProvider() else {
            AppLog.web.debug("StreamHub: sharing stopped, disconnecting all clients.")
            disconnectAllClients()
            return
        }

        guard let frame = frameProvider() else { return }
        let frameData = makeMJPEGFramePayload(
            frame: frame,
            boundary: WebRequestHandler.streamBoundary
        )

        for key in Array(clients.keys) {
            enqueue(frameData, to: key)
        }
    }

    private func enqueue(_ frameData: Data, to key: ObjectIdentifier) {
        guard var state = clients[key] else { return }
        if state.isSending {
            // Keep only the latest frame for slow clients to avoid backpressure cascade.
            state.pendingFrame = frameData
            clients[key] = state
            return
        }

        state.isSending = true
        clients[key] = state
        send(frameData, to: key)
    }

    private func send(_ frameData: Data, to key: ObjectIdentifier) {
        guard let state = clients[key] else { return }
        state.connection.sendFrame(frameData) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard var current = self.clients[key] else { return }

                if let error {
                    self.onSendError(error)
                    self.removeClient(for: key, cancelConnection: true)
                    return
                }

                if let pending = current.pendingFrame {
                    current.pendingFrame = nil
                    self.clients[key] = current
                    self.send(pending, to: key)
                    return
                }

                current.isSending = false
                self.clients[key] = current
            }
        }
    }
}
