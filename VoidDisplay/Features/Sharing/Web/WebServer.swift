import CryptoKit
import Network
import OSLog

@MainActor
final class WebServer {
    private enum InitError: Error {
        case missingDisplayPageResource
    }

    private final class BundleToken {}

    enum ListenerStartResult {
        case ready(boundPort: UInt16)
        case failed(error: Error)
        case timedOut
    }

    private enum LifecycleError: Error {
        case listenerCancelled
        case listenerMissingBoundPort
    }

    nonisolated private static let requestHeaderTerminator = Data("\r\n\r\n".utf8)
    nonisolated private static let maxRequestBytes = 32 * 1024
    nonisolated private static let receiveChunkSize = 4096
    nonisolated private static let maxSignalBufferBytes = 256 * 1024

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
          <p>Signal routes:</p>
          <ul>
            <li><code>/signal</code> main display websocket</li>
            <li><code>/signal/{id}</code> websocket for target id</li>
          </ul>
        </body>
        </html>
        """
    }

    private static func loadDisplayPageTemplate() throws -> String {
        let bundles: [Bundle] = [Bundle.main, Bundle(for: BundleToken.self)]
        for bundle in bundles {
            if let path = bundle.path(forResource: "displayPage", ofType: "html") {
                return try String(contentsOfFile: path, encoding: .utf8)
            }
        }

#if DEBUG
        // Unit tests running as logic tests may not execute inside the app bundle.
        let sourcePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("displayPage.html")
            .path
        if FileManager.default.fileExists(atPath: sourcePath) {
            return try String(contentsOfFile: sourcePath, encoding: .utf8)
        }
#endif

        throw InitError.missingDisplayPageResource
    }

    private struct ActiveConnection {
        let target: ShareTarget
        let clientID: String
        let connection: NWConnection
    }

    private var listener: NWListener?
    private let displayPageTemplate: String
    private let requestHandler = WebRequestHandler()
    private var activeConnections: [ObjectIdentifier: ActiveConnection] = [:]
    private var signalDecodersByConnectionKey: [ObjectIdentifier: WebSocketFrameDecoder] = [:]
    private let targetStateProvider: @MainActor @Sendable (ShareTarget) -> ShareTargetState
    private let sessionHubProvider: @MainActor @Sendable (ShareTarget) -> WebRTCSessionHub?
    private let sharingEventSink: @Sendable (SharingSessionEvent) -> Void
    private let onListenerStopped: (@MainActor @Sendable (WebServiceServerStopReason) -> Void)?
    private var didNotifyListenerStopped = false
    private var startupWaiter: CheckedContinuation<ListenerStartResult, Never>?
    private var startupTimeoutTask: Task<Void, Never>?
    nonisolated private let networkQueue = DispatchQueue(
        label: "com.developerchen.voiddisplay.web.network",
        qos: .userInitiated
    )

    init(
        using port: NWEndpoint.Port = .http,
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        sessionHubProvider: @escaping @MainActor @Sendable (ShareTarget) -> WebRTCSessionHub?,
        sharingEventSink: @escaping @Sendable (SharingSessionEvent) -> Void,
        onListenerStopped: (@MainActor @Sendable (WebServiceServerStopReason) -> Void)? = nil
    ) throws {
        self.targetStateProvider = targetStateProvider
        self.sessionHubProvider = sessionHubProvider
        self.sharingEventSink = sharingEventSink
        self.onListenerStopped = onListenerStopped

        displayPageTemplate = try Self.loadDisplayPageTemplate()

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        listener = try NWListener(using: params, on: port)
        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleListenerState(state)
            }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleConnectionState(state, for: connection)
                }
            }
            connection.start(queue: self.networkQueue)
            self.receiveHTTPRequest(on: connection) { [weak self] content in
                guard let self else { return }
                self.processRequest(content, on: connection)
            }
        }
    }

    deinit {
        listener?.cancel()
        listener = nil
    }

    func startListener(timeout: TimeInterval = 1.5) async -> ListenerStartResult {
        guard listener != nil else {
            return .failed(error: LifecycleError.listenerCancelled)
        }

        guard startupWaiter == nil else {
            return .failed(error: LifecycleError.listenerCancelled)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completeStartupWaiter(result: .failed(error: LifecycleError.listenerCancelled))
                startupWaiter = continuation
                didNotifyListenerStopped = false

                let timeoutDuration = Duration.seconds(max(timeout, 0))
                startupTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeoutDuration)
                    } catch {
                        return
                    }
                    self?.completeStartupWaiter(result: .timedOut)
                }
                listener?.start(queue: networkQueue)
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.stopListener(reason: .startupCancelled)
            }
        }
    }

    func listeningPort() -> UInt16? {
        listener?.port?.rawValue
    }

    func disconnectAllStreamClients() {
        for client in activeConnections.values {
            if let hub = sessionHub(for: client.target) {
                hub.removeClient(client.connection)
            }
            client.connection.cancel()
        }
        activeConnections.removeAll()
        signalDecodersByConnectionKey.removeAll()
    }

    var activeStreamClientCount: Int {
        activeConnections.count
    }

    func streamClientCount(for target: ShareTarget) -> Int {
        activeConnections.values.filter { $0.target == target }.count
    }

    func stopListener(reason: WebServiceServerStopReason = .requested) {
        notifyListenerStoppedIfNeeded(reason: reason)
        completeStartupWaiter(result: .failed(error: LifecycleError.listenerCancelled))
        teardownListener()
    }

    private func teardownListener() {
        disconnectAllStreamClients()
        listener?.cancel()
        listener = nil
    }

    private func connectionKey(for connection: NWConnection) -> ObjectIdentifier {
        ObjectIdentifier(connection)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            AppLog.web.info("Web listener ready.")
            guard let boundPort = listener?.port?.rawValue else {
                completeStartupWaiter(result: .failed(error: LifecycleError.listenerMissingBoundPort))
                return
            }
            completeStartupWaiter(result: .ready(boundPort: boundPort))
        case .failed(let error):
            AppErrorMapper.logFailure("Web listener failed", error: error, logger: AppLog.web)
            completeStartupWaiter(result: .failed(error: error))
            notifyListenerStoppedIfNeeded(reason: .listenerFailed)
            teardownListener()
        case .cancelled:
            AppLog.web.info("Web listener cancelled.")
            completeStartupWaiter(result: .failed(error: LifecycleError.listenerCancelled))
            notifyListenerStoppedIfNeeded(reason: .listenerCancelled)
            teardownListener()
        default:
            break
        }
    }

    private func notifyListenerStoppedIfNeeded(reason: WebServiceServerStopReason) {
        guard !didNotifyListenerStopped else { return }
        didNotifyListenerStopped = true
        onListenerStopped?(reason)
    }

    private func completeStartupWaiter(result: ListenerStartResult) {
        guard let startupWaiter else { return }
        self.startupWaiter = nil
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        startupWaiter.resume(returning: result)
    }

    private func handleConnectionState(_ state: NWConnection.State, for connection: NWConnection) {
        switch state {
        case .failed(let error):
            let endpoint = Self.endpointDescription(for: connection)
            Self.logConnectionIssue("Connection failed [\(endpoint)]", error: error)
            removeSignalClient(connection, cancelConnection: true)
        case .cancelled:
            let endpoint = Self.endpointDescription(for: connection)
            AppLog.web.debug("Connection cancelled [\(endpoint, privacy: .public)].")
            removeSignalClient(connection, cancelConnection: false)
        default:
            break
        }
    }

    private func removeSignalClient(_ connection: NWConnection, cancelConnection: Bool) {
        let key = connectionKey(for: connection)
        signalDecodersByConnectionKey.removeValue(forKey: key)
        if let active = activeConnections.removeValue(forKey: key) {
            if let hub = sessionHub(for: active.target) {
                hub.removeClient(connection)
            }
        }
        if cancelConnection {
            connection.cancel()
        }
    }

    private func sessionHub(for target: ShareTarget) -> WebRTCSessionHub? {
        sessionHubProvider(target)
    }

    private func displayPage(for target: ShareTarget) -> String {
        let title: String
        switch target {
        case .main:
            title = "Main Display"
        case .id(let id):
            title = "Display \(id)"
        }
        return displayPageTemplate
            .replacingOccurrences(of: "__PAGE_TITLE__", with: title)
            .replacingOccurrences(of: "__SIGNAL_PATH__", with: target.signalPath)
            .replacingOccurrences(of: "__BOOTSTRAP_JSON__", with: makeDisplayPageBootstrapJSON())
    }

    private func makeDisplayPageBootstrapJSON() -> String {
        WebRTCIceServerProvider.browserBootstrapJSON()
    }

    private func processRequest(_ content: Data?, on connection: NWConnection) {
        let endpoint = Self.endpointDescription(for: connection)
        guard let content else {
            AppLog.web.debug("Received empty request content from \(endpoint, privacy: .public); closing connection.")
            connection.cancel()
            return
        }
        guard let request = parseHTTPRequest(from: content) else {
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
        case .openSignalSocket(let target):
            guard isValidWebSocketUpgrade(request.headers) else {
                sendResponseAndClose(
                    requestHandler.responseData(for: .badRequest),
                    on: connection,
                    failureContext: "Reject invalid websocket upgrade"
                )
                return
            }
            openSignalSocket(on: connection, target: target, headers: request.headers)
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

    private func openSignalSocket(on connection: NWConnection, target: ShareTarget, headers: [String: String]) {
        let endpoint = Self.endpointDescription(for: connection)
        AppLog.web.info("WebServer: [\(endpoint)] Initiating signaling WebSocket upgrade for target: \(String(describing: target)).")
        guard let hub = sessionHub(for: target),
              let acceptValue = makeWebSocketAcceptValue(headers: headers) else {
            sendResponseAndClose(
                requestHandler.responseData(for: .sharingUnavailable),
                on: connection,
                failureContext: "Reject missing live hub"
            )
            return
        }

        let wsKeyLength = headers["sec-websocket-key"]?.count ?? 0
        AppLog.web.debug(
            "WebServer: [\(endpoint)] WebSocket headers validated (keyLength=\(wsKeyLength), acceptLength=\(acceptValue.count))."
        )

        let responseString = "HTTP/1.1 101 Switching Protocols\r\n" +
                             "Upgrade: websocket\r\n" +
                             "Connection: Upgrade\r\n" +
                             "Sec-WebSocket-Accept: \(acceptValue)\r\n" +
                             "\r\n"
        let debugStr = responseString
            .replacingOccurrences(of: "\r", with: "<CR>")
            .replacingOccurrences(of: "\n", with: "<LF>\n")
        AppLog.web.debug("WebServer: [\(endpoint)] Sending websocket upgrade response:\n\(debugStr, privacy: .public)")
        let response = Data(responseString.utf8)
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    AppLog.web.error("WebServer: [\(endpoint)] WebSocket upgrade response failed: \(String(describing: error)).")
                    AppErrorMapper.logFailure("Send websocket upgrade response", error: error, logger: AppLog.web)
                    connection.cancel()
                    return
                }
                AppLog.web.info("WebServer: [\(endpoint)] WebSocket upgrade succeeded.")
                let sharingEventSink = self.sharingEventSink
                let addResult = hub.addClient(
                    connection,
                    target: target,
                    makeClientID: { UUID().uuidString },
                    eventSink: { event in
                        sharingEventSink(event)
                    }
                )
                guard case .accepted(let clientID) = addResult else {
                    if case .rejected(let reason) = addResult {
                        hub.sendRejection(reason: reason, to: connection)
                    }
                    connection.cancel()
                    return
                }
                let key = self.connectionKey(for: connection)
                self.activeConnections[key] = ActiveConnection(
                    target: target,
                    clientID: clientID,
                    connection: connection
                )
                self.signalDecodersByConnectionKey[key] = WebSocketFrameDecoder(
                    maxFramePayloadBytes: Self.maxSignalBufferBytes,
                    maxContinuationPayloadBytes: Self.maxSignalBufferBytes,
                    requiresMaskedFrames: true
                )
                self.startSignalReceiveLoop(on: connection, target: target)
            }
        })
    }

    nonisolated private func startSignalReceiveLoop(on connection: NWConnection, target: ShareTarget) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            if let error = error {
                AppLog.web.warning("WebServer: WebSocket receive error: \(error)")
                connection.cancel()
                return
            }
            if isComplete {
                AppLog.web.info("WebServer: WebSocket client closed connection")
                connection.cancel()
                return
            }
            guard let self else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                let key = self.connectionKey(for: connection)
                guard let decoder = self.signalDecodersByConnectionKey[key] else {
                    self.removeSignalClient(connection, cancelConnection: true)
                    return
                }

                let decoded = decoder.ingest(content)
                if decoder.remainder.count > Self.maxSignalBufferBytes {
                    AppLog.web.warning(
                        "WebServer: Closing signaling connection due to oversized buffered signal data."
                    )
                    self.sendCloseAndRemoveSignalClient(connection, code: 1009)
                    return
                }

                if let decodeError = decoded.errors.first {
                    let closeCode = Self.closeCode(for: decodeError)
                    AppLog.web.warning(
                        "WebServer: Closing signaling connection due to websocket protocol violation: \(String(describing: decodeError), privacy: .public)"
                    )
                    self.sendCloseAndRemoveSignalClient(connection, code: closeCode)
                    return
                }

                for frame in decoded.frames {
                    switch frame {
                    case .text(let text):
                        self.sessionHub(for: target)?.receiveSignalText(text, from: connection)
                    case .ping(let payload):
                        connection.send(
                            content: encodeWebSocketPongFrame(payload),
                            completion: .contentProcessed { error in
                                if let error {
                                    Task { @MainActor in
                                        Self.logConnectionIssue("Send websocket pong frame", error: error)
                                    }
                                }
                            }
                        )
                    case .close:
                        self.sendCloseAndRemoveSignalClient(connection, code: 1000)
                    case .binary:
                        let errorFrame = encodeWebSocketTextFrame(
                            #"{"type":"error","reason":"binary_signal_not_allowed"}"#
                        )
                        connection.send(content: errorFrame, completion: .contentProcessed { [weak self] _ in
                            Task { @MainActor [weak self] in
                                self?.sendCloseAndRemoveSignalClient(connection, code: 1003)
                            }
                        })
                    case .pong:
                        break
                    }
                }

                guard self.activeConnections[key] != nil else {
                    return
                }
                self.startSignalReceiveLoop(on: connection, target: target)
            }
        }
    }

    nonisolated private static func closeCode(for decodeError: WebSocketFrameDecodeError) -> UInt16 {
        switch decodeError {
        case .framePayloadTooLarge, .continuationPayloadTooLarge, .oversizedControlFramePayload:
            return 1009
        case .invalidUTF8Text:
            return 1007
        default:
            return 1002
        }
    }

    private func sendCloseAndRemoveSignalClient(_ connection: NWConnection, code: UInt16) {
        connection.send(
            content: encodeWebSocketCloseFrame(code: code),
            completion: .contentProcessed { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.removeSignalClient(connection, cancelConnection: true)
                }
            }
        )

        // Ensure teardown still completes when NWConnection send completion is delayed or dropped.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            self?.removeSignalClient(connection, cancelConnection: true)
        }
    }

    private func isValidWebSocketUpgrade(_ headers: [String: String]) -> Bool {
        guard let connection = headers["connection"]?.lowercased(),
              connection.contains("upgrade"),
              headers["upgrade"]?.lowercased() == "websocket",
              headers["sec-websocket-version"] == "13",
              headers["sec-websocket-key"] != nil else {
            return false
        }
        return true
    }

    private func makeWebSocketAcceptValue(headers: [String: String]) -> String? {
        guard let key = headers["sec-websocket-key"] else { return nil }
        let value = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(value.utf8))
        return Data(digest).base64EncodedString()
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
                    completion(nil)
                }
            }
        }
    }
}
