//
//  WebServer.swift
//  VoidDisplay
//
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

    nonisolated private static func endpointDescription(for connection: NWConnection) -> String {
        String(describing: connection.endpoint)
    }

    private static func logConnectionIssue(_ operation: String, error: Error) {
        if shouldTreatAsExpectedClientDisconnect(error) {
            AppLog.web.debug(
                "\(operation, privacy: .public) ended by client disconnect: \(String(describing: error), privacy: .public)"
            )
            return
        }
        AppErrorMapper.logFailure(operation, error: error, logger: AppLog.web)
    }

    private static func makeRootPage() -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1.0" />
          <title>VoidDisplay Share</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 24px; line-height: 1.6; }
            code { background: #f3f3f3; padding: 2px 6px; border-radius: 4px; }
          </style>
        </head>
        <body>
          <h1>VoidDisplay Share</h1>
          <p>Page routes:</p>
          <ul>
            <li><code>/display</code> main display page</li>
            <li><code>/display/{id}</code> display page for target id</li>
          </ul>
          <p>Stream routes:</p>
          <ul>
            <li><code>/stream</code> main display stream</li>
            <li><code>/stream/{id}</code> stream for target id</li>
          </ul>
        </body>
        </html>
        """
    }

    private var listener: NWListener?
    private let displayPageTemplate: String
    private let requestHandler = WebRequestHandler()
    private var streamHubs: [ShareTarget: StreamHub] = [:]
    private var streamTargetByConnectionKey: [ObjectIdentifier: ShareTarget] = [:]
    private let targetStateProvider: @MainActor @Sendable (ShareTarget) -> ShareTargetState
    private let frameProvider: @MainActor @Sendable (ShareTarget) -> Data?
    private let onListenerStopped: (@MainActor @Sendable () -> Void)?
    private var didNotifyListenerStopped = false
    private var startupWaiter: CheckedContinuation<Bool, Never>?
    private var startupTimeoutTask: Task<Void, Never>?
    nonisolated private let networkQueue = DispatchQueue(
        label: "com.developerchen.voiddisplay.web.network",
        qos: .userInitiated
    )

    private func connectionKey(for connection: NWConnection) -> ObjectIdentifier {
        ObjectIdentifier(connection)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            AppLog.web.info("Web listener ready.")
            completeStartupWaiter(result: true)
        case .failed(let error):
            AppErrorMapper.logFailure("Web listener failed", error: error, logger: AppLog.web)
            completeStartupWaiter(result: false)
            notifyListenerStoppedIfNeeded()
            stopListener()
        case .cancelled:
            AppLog.web.info("Web listener cancelled.")
            completeStartupWaiter(result: false)
            notifyListenerStoppedIfNeeded()
        default:
            break
        }
    }

    private func notifyListenerStoppedIfNeeded() {
        guard !didNotifyListenerStopped else { return }
        didNotifyListenerStopped = true
        onListenerStopped?()
    }

    private func completeStartupWaiter(result: Bool) {
        guard let startupWaiter else { return }
        self.startupWaiter = nil
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        startupWaiter.resume(returning: result)
    }

    private func removeStreamClient(_ connection: NWConnection, cancelConnection: Bool) {
        let key = connectionKey(for: connection)
        if let target = streamTargetByConnectionKey.removeValue(forKey: key),
           let hub = streamHubs[target] {
            hub.removeClient(connection)
        }
        if cancelConnection {
            connection.cancel()
        }
    }

    private func handleConnectionState(_ state: NWConnection.State, for connection: NWConnection) {
        switch state {
        case .failed(let error):
            let endpoint = Self.endpointDescription(for: connection)
            Self.logConnectionIssue("Connection failed [\(endpoint)]", error: error)
            removeStreamClient(connection, cancelConnection: true)
        case .cancelled:
            let endpoint = Self.endpointDescription(for: connection)
            AppLog.web.debug("Connection cancelled [\(endpoint, privacy: .public)].")
            removeStreamClient(connection, cancelConnection: false)
        default:
            break
        }
    }

    private func streamHub(for target: ShareTarget) -> StreamHub {
        if let existing = streamHubs[target] {
            return existing
        }

        let hub = StreamHub(
            isSharingProvider: { [weak self] in
                self?.targetStateProvider(target) == .active
            },
            frameProvider: { [weak self] in
                self?.frameProvider(target)
            },
            onSendError: { error in
                Self.logConnectionIssue("Stream frame send", error: error)
            }
        )
        streamHubs[target] = hub
        return hub
    }

    private func displayPage(for target: ShareTarget) -> String {
        let streamPath = target.streamPath
        let title: String
        switch target {
        case .main:
            title = "Main Display"
        case .id(let id):
            title = "Display \(id)"
        }
        return displayPageTemplate
            .replacingOccurrences(of: "__PAGE_TITLE__", with: title)
            .replacingOccurrences(of: "__STREAM_PATH__", with: streamPath)
    }

    private func processRequest(
        _ content: Data?,
        on connection: NWConnection
    ) {
        let endpoint = Self.endpointDescription(for: connection)
        guard let content else {
            AppLog.web.debug("Received empty request content from \(endpoint, privacy: .public); closing connection.")
            connection.cancel()
            return
        }
        guard let request = parseHTTPRequest(from: content) else {
            AppLog.web.notice(
                "Failed to parse HTTP request from \(endpoint, privacy: .public), bytes=\(content.count); returning bad request."
            )
            sendResponseAndClose(
                requestHandler.responseData(for: .badRequest),
                on: connection,
                failureContext: "Send bad request response"
            )
            return
        }

        let decision = requestHandler.decision(
            forMethod: request.method,
            path: request.path,
            targetStateProvider: { [weak self] target in
                self?.targetStateProvider(target) ?? .unknown
            }
        )
        switch decision {
        case .showRootPage, .showDisplayPage, .openStream:
            AppLog.web.debug(
                "HTTP request from \(endpoint, privacy: .public): method=\(request.method), path=\(request.path), decision=\(String(describing: decision), privacy: .public)"
            )
        case .badRequest, .sharingUnavailable, .methodNotAllowed, .notFound:
            AppLog.web.notice(
                "HTTP request from \(endpoint, privacy: .public): method=\(request.method), path=\(request.path), decision=\(String(describing: decision), privacy: .public)"
            )
        }

        switch decision {
        case .showRootPage:
            sendResponseAndClose(
                requestHandler.responseData(
                    for: .showRootPage,
                    htmlBody: Self.makeRootPage()
                ),
                on: connection,
                failureContext: "Send root page response"
            )
        case .showDisplayPage(let target):
            sendResponseAndClose(
                requestHandler.responseData(
                    for: decision,
                    htmlBody: displayPage(for: target)
                ),
                on: connection,
                failureContext: "Send display page response"
            )
        case .openStream(let target):
            openStream(for: connection, target: target)
        case .badRequest, .sharingUnavailable, .methodNotAllowed, .notFound:
            sendResponseAndClose(
                requestHandler.responseData(for: decision),
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

    private func openStream(for connection: NWConnection, target: ShareTarget) {
        let endpoint = Self.endpointDescription(for: connection)
        AppLog.web.debug("Open MJPEG stream for client \(endpoint, privacy: .public).")
        connection.send(
            content: requestHandler.responseData(for: .openStream(target)),
            completion: .contentProcessed { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error {
                        AppErrorMapper.logFailure("Send stream response header", error: error, logger: AppLog.web)
                        connection.cancel()
                        return
                    }
                    streamHub(for: target).addClient(connection)
                    streamTargetByConnectionKey[connectionKey(for: connection)] = target
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
                    let endpoint = Self.endpointDescription(for: connection)
                    AppLog.web.notice(
                        "HTTP request header exceeds max size from \(endpoint, privacy: .public); closing connection."
                    )
                    completion(nil)
                }
            }
        }
    }

    init(
        using port: NWEndpoint.Port = .http,
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        frameProvider: @escaping @MainActor @Sendable (ShareTarget) -> Data?,
        onListenerStopped: (@MainActor @Sendable () -> Void)? = nil
    ) throws {
        self.targetStateProvider = targetStateProvider
        self.frameProvider = frameProvider
        self.onListenerStopped = onListenerStopped

        guard let displayPagePath = Bundle.main.path(forResource: "displayPage", ofType: "html") else {
            throw InitError.missingDisplayPageResource
        }
        displayPageTemplate = try String(contentsOfFile: displayPagePath, encoding: .utf8)

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
                self.processRequest(content, on: connection)
            }
        }
    }

    func startListener(timeout: TimeInterval = 1.5) async -> Bool {
        guard listener != nil else { return false }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completeStartupWaiter(result: false)
                startupWaiter = continuation
                didNotifyListenerStopped = false

                let timeoutNanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                startupTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    self?.completeStartupWaiter(result: false)
                }
                listener?.start(queue: networkQueue)
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.completeStartupWaiter(result: false)
            }
        }
    }

    func listeningPort() -> UInt16? {
        listener?.port?.rawValue
    }

    func disconnectAllStreamClients() {
        for hub in streamHubs.values {
            hub.disconnectAllClients()
        }
        streamTargetByConnectionKey.removeAll()
    }

    var activeStreamClientCount: Int {
        streamHubs.values.reduce(0) { partialResult, hub in
            partialResult + hub.activeClientCount
        }
    }

    func streamClientCount(for target: ShareTarget) -> Int {
        streamHubs[target]?.activeClientCount ?? 0
    }

    func stopListener() {
        completeStartupWaiter(result: false)
        disconnectAllStreamClients()
        listener?.cancel()
        listener = nil
    }
}
