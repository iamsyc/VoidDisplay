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
    nonisolated private static let requestHeaderTerminator = Data("\r\n\r\n".utf8)
    nonisolated private static let maxRequestBytes = 32 * 1024
    nonisolated private static let receiveChunkSize = 4096

    private static func logConnectionIssue(_ operation: String, error: Error) {
        if shouldTreatAsExpectedClientDisconnect(error) {
            AppLog.web.debug(
                "\(operation, privacy: .public) ended by client disconnect: \(String(describing: error), privacy: .public)"
            )
            return
        }
        AppErrorMapper.logFailure(operation, error: error, logger: AppLog.web)
    }

    private var listener: NWListener?
    private let displayPage: String
    private let streamHub: StreamHub
    private let requestHandler = WebRequestHandler()
    nonisolated private let networkQueue = DispatchQueue(
        label: "phineas.mac.FreelyDisplay.web.network",
        qos: .userInitiated
    )

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            AppLog.web.info("Web listener ready.")
        case .failed(let error):
            AppErrorMapper.logFailure("Web listener failed", error: error, logger: AppLog.web)
            stopListener()
        case .cancelled:
            AppLog.web.info("Web listener cancelled.")
        default:
            break
        }
    }

    private func handleConnectionState(_ state: NWConnection.State, for connection: NWConnection) {
        switch state {
        case .failed(let error):
            Self.logConnectionIssue("Connection failed", error: error)
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
            AppLog.web.notice("Failed to parse HTTP request; returning bad request response.")
            sendResponseAndClose(
                requestHandler.responseData(for: .badRequest, displayPage: displayPage),
                on: connection,
                failureContext: "Send bad request response"
            )
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
        case .badRequest, .sharingUnavailable, .methodNotAllowed, .notFound:
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

    nonisolated private func receiveHTTPRequest(
        on connection: NWConnection,
        completion: @escaping @MainActor (Data?) -> Void
    ) {
        let accumulator = HTTPRequestAccumulator(
            headerTerminator: Self.requestHeaderTerminator,
            maxBytes: Self.maxRequestBytes
        )
        Self.receiveHTTPRequestChunk(on: connection, accumulator: accumulator, completion: completion)
    }

    nonisolated private static func receiveHTTPRequestChunk(
        on connection: NWConnection,
        accumulator: HTTPRequestAccumulator,
        completion: @escaping @MainActor (Data?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunkSize) { content, _, isComplete, error in
            if let error {
                Task { @MainActor in
                    Self.logConnectionIssue("Receive HTTP request", error: error)
                    completion(nil)
                }
                return
            }

            var nextAccumulator = accumulator
            switch nextAccumulator.ingest(chunk: content, isComplete: isComplete) {
            case .waiting:
                Self.receiveHTTPRequestChunk(on: connection, accumulator: nextAccumulator, completion: completion)
            case .complete(let completedData):
                Task { @MainActor in
                    completion(completedData)
                }
            case .invalidTooLarge:
                Task { @MainActor in
                    AppLog.web.notice("HTTP request header exceeds max size; closing connection.")
                    completion(nil)
                }
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
            frameProvider: frameProvider,
            onSendError: { error in
                Self.logConnectionIssue("Stream frame send", error: error)
            }
        )
        guard let displayPagePath = Bundle.main.path(forResource: "displayPage", ofType: "html") else {
            throw InitError.missingDisplayPageResource
        }
        displayPage = try String(contentsOfFile: displayPagePath, encoding: .utf8)
        listener = try NWListener(using: .tcp, on: port)
        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleListenerState(state)
            }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.handleConnectionState(state, for: connection)
                }
            }
            connection.start(queue: self.networkQueue)
            self.receiveHTTPRequest(on: connection) { [weak self] content in
                guard let self else { return }
                self.processRequest(content, on: connection, isSharingProvider: isSharingProvider)
            }
        }
    }

    func startListener() {
        listener?.start(queue: networkQueue)
    }

    func listeningPort() -> UInt16? {
        listener?.port?.rawValue
    }

    func disconnectAllStreamClients() {
        streamHub.disconnectAllClients()
    }

    func stopListener() {
        disconnectAllStreamClients()
        listener?.cancel()
        listener = nil
    }
    
}
