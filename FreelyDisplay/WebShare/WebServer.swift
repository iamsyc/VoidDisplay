//
//  WebServer.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/14.
//

import Network
import OSLog

@MainActor
final class WebServer {
    private enum InitError: Error {
        case missingDisplayPageResource
    }
    private static let requestHeaderTerminator = Data("\r\n\r\n".utf8)
    private static let maxRequestBytes = 32 * 1024
    private static let receiveChunkSize = 4096

    private final class StreamHub {
        private struct ClientState {
            let connection: NWConnection
            var isSending = false
            var pendingFrame: Data?
        }

        private var clients: [ObjectIdentifier: ClientState] = [:]
        private var timer: DispatchSourceTimer?
        private let isSharingProvider: @MainActor @Sendable () -> Bool
        private let frameProvider: @MainActor @Sendable () -> Data?
        private let frameInterval: DispatchTimeInterval = .milliseconds(100)

        init(
            isSharingProvider: @escaping @MainActor @Sendable () -> Bool,
            frameProvider: @escaping @MainActor @Sendable () -> Data?
        ) {
            self.isSharingProvider = isSharingProvider
            self.frameProvider = frameProvider
        }

        func addClient(_ connection: NWConnection) {
            let key = ObjectIdentifier(connection)
            clients[key] = ClientState(connection: connection)
            AppLog.web.info("StreamHub: added client, active=\(self.clients.count)")
            startTimerIfNeeded()
        }

        func removeClient(_ connection: NWConnection) {
            removeClient(for: ObjectIdentifier(connection), cancelConnection: false)
        }

        func disconnectAllClients() {
            let keys = Array(clients.keys)
            for key in keys {
                removeClient(for: key, cancelConnection: true)
            }
            stopTimer()
        }

        private func removeClient(for key: ObjectIdentifier, cancelConnection: Bool) {
            guard let removed = clients.removeValue(forKey: key) else { return }
            if cancelConnection {
                removed.connection.cancel()
            }
            AppLog.web.info("StreamHub: removed client, active=\(self.clients.count)")
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
            AppLog.web.info("StreamHub: timer started")
        }

        private func stopTimer() {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            AppLog.web.info("StreamHub: timer stopped")
        }

        private func tick() {
            guard !clients.isEmpty else {
                stopTimer()
                return
            }

            guard isSharingProvider() else {
                AppLog.web.info("StreamHub: sharing stopped, disconnecting all clients.")
                disconnectAllClients()
                return
            }

            guard let frame = frameProvider() else { return }
            let frameData = makeFramePayload(frame: frame)

            for key in Array(clients.keys) {
                enqueue(frameData, to: key)
            }
        }

        private func makeFramePayload(frame: Data) -> Data {
            let boundary = "--\(WebRequestHandler.streamBoundary)\r\n"
            let contentHeader = "Content-Type: image/jpeg\r\n"
            let contentLength = "Content-Length: \(frame.count)\r\n\r\n"
            return Data(boundary.utf8)
            + Data(contentHeader.utf8)
            + Data(contentLength.utf8)
            + frame
            + Data("\r\n".utf8)
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
            state.connection.send(content: frameData, completion: .contentProcessed({ [weak self] error in
                guard let self else { return }
                guard var current = self.clients[key] else { return }

                if let error {
                    AppErrorMapper.logFailure("Stream frame send", error: error, logger: AppLog.web)
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
            }))
        }
    }

    private var listener: NWListener?
    private let displayPage: String
    private let streamHub: StreamHub
    private let requestHandler = WebRequestHandler()

    private func handleConnectionState(_ state: NWConnection.State, for connection: NWConnection) {
        switch state {
        case .failed(let error):
            AppErrorMapper.logFailure("Connection failed", error: error, logger: AppLog.web)
            streamHub.removeClient(connection)
            connection.cancel()
        case .cancelled:
            AppLog.web.info("Connection cancelled.")
            streamHub.removeClient(connection)
        default:
            break
        }
    }

    private func processRequest(
        _ content: Data?,
        on connection: NWConnection,
        isSharingProvider: @escaping @MainActor @Sendable () -> Bool
    ) {
        guard let content else {
            AppLog.web.notice("Received empty request content; closing connection.")
            connection.cancel()
            return
        }
        guard let request = parseHTTPRequest(from: content) else {
            AppLog.web.notice("Failed to parse HTTP request; closing connection.")
            connection.cancel()
            return
        }

        let decision = requestHandler.decision(
            forMethod: request.method,
            path: request.path,
            isSharing: isSharingProvider()
        )
        AppLog.web.info(
            "HTTP request: method=\(request.method), path=\(request.path), decision=\(String(describing: decision))"
        )

        switch decision {
        case .showDisplayPage:
            sendResponseAndClose(
                requestHandler.responseData(for: .showDisplayPage, displayPage: displayPage),
                on: connection,
                failureContext: "Send display page response"
            )
        case .openStream:
            openStream(for: connection)
        case .sharingUnavailable, .methodNotAllowed, .notFound:
            sendResponseAndClose(
                requestHandler.responseData(for: decision, displayPage: displayPage),
                on: connection,
                failureContext: "Send HTTP error response"
            )
        }
    }

    private func sendResponseAndClose(
        _ response: Data,
        on connection: NWConnection,
        failureContext: String
    ) {
        connection.send(content: response, completion: .contentProcessed { error in
            Task { @MainActor in
                if let error {
                    AppErrorMapper.logFailure(failureContext, error: error, logger: AppLog.web)
                }
                connection.cancel()
            }
        })
    }

    private func openStream(for connection: NWConnection) {
        AppLog.web.info("Open MJPEG stream for client.")
        connection.send(
            content: requestHandler.responseData(for: .openStream, displayPage: displayPage),
            completion: .contentProcessed { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error {
                        AppErrorMapper.logFailure("Send stream response header", error: error, logger: AppLog.web)
                        connection.cancel()
                        return
                    }
                    streamHub.addClient(connection)
                }
            }
        )
    }

    private func receiveHTTPRequest(
        on connection: NWConnection,
        accumulated: Data = Data(),
        completion: @escaping @MainActor (Data?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunkSize) { [weak self] content, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    AppErrorMapper.logFailure("Receive HTTP request", error: error, logger: AppLog.web)
                    completion(nil)
                    return
                }

                var nextData = accumulated
                if let content, !content.isEmpty {
                    nextData.append(content)
                }

                if nextData.count > Self.maxRequestBytes {
                    AppLog.web.notice("HTTP request header exceeds max size; closing connection.")
                    completion(nil)
                    return
                }

                if nextData.range(of: Self.requestHeaderTerminator) != nil {
                    completion(nextData)
                    return
                }

                if isComplete {
                    completion(nextData.isEmpty ? nil : nextData)
                    return
                }

                self.receiveHTTPRequest(on: connection, accumulated: nextData, completion: completion)
            }
        }
    }

    init(
        using port:NWEndpoint.Port = .http,
        isSharingProvider: @escaping @MainActor @Sendable () -> Bool,
        frameProvider: @escaping @MainActor @Sendable () -> Data?
    ) throws {
        self.streamHub = StreamHub(
            isSharingProvider: isSharingProvider,
            frameProvider: frameProvider
        )
        guard let displayPagePath = Bundle.main.path(forResource: "displayPage", ofType: "html") else {
            throw InitError.missingDisplayPageResource
        }
        displayPage = try String(contentsOfFile: displayPagePath, encoding: .utf8)
        listener = try NWListener(using: .tcp, on: port)
        listener?.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: .main)
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleConnectionState(state, for: connection)
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiveHTTPRequest(on: connection) { content in
                    self.processRequest(content, on: connection, isSharingProvider: isSharingProvider)
                }
            }
        }
    }

    func startListener() {
        listener?.start(queue: .main)
    }

    func disconnectStreamClient() {
        streamHub.disconnectAllClients()
    }

    func stopListener() {
        disconnectStreamClient()
        listener?.cancel()
        listener = nil
    }
    
}
