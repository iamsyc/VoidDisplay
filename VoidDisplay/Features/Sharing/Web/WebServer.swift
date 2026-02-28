import CryptoKit
import Network
import OSLog

@MainActor
final class WebServer {
    private enum InitError: Error {
        case missingDisplayPageResource
    }

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
    nonisolated private static let maxLiveSocketBufferBytes = 64 * 1024
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
          <p>Live routes:</p>
          <ul>
            <li><code>/live</code> main display websocket</li>
            <li><code>/live/{id}</code> websocket for target id</li>
          </ul>
        </body>
        </html>
        """
    }

    private var listener: NWListener?
    private let displayPageTemplate: String
    private let requestHandler = WebRequestHandler()
    private var liveHubs: [ShareTarget: LiveSocketHub] = [:]
    private var liveTargetByConnectionKey: [ObjectIdentifier: ShareTarget] = [:]
    private var liveReceiveBufferByConnectionKey: [ObjectIdentifier: Data] = [:]
    private let targetStateProvider: @MainActor @Sendable (ShareTarget) -> ShareTargetState
    private let liveHubProvider: @MainActor @Sendable (ShareTarget) -> LiveSocketHub?
    private let onListenerStopped: (@MainActor @Sendable () -> Void)?
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
        liveHubProvider: @escaping @MainActor @Sendable (ShareTarget) -> LiveSocketHub?,
        onListenerStopped: (@MainActor @Sendable () -> Void)? = nil
    ) throws {
        self.targetStateProvider = targetStateProvider
        self.liveHubProvider = liveHubProvider
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

    func startListener(timeout: TimeInterval = 1.5) async -> ListenerStartResult {
        guard listener != nil else {
            return .failed(error: LifecycleError.listenerCancelled)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completeStartupWaiter(result: .failed(error: LifecycleError.listenerCancelled))
                startupWaiter = continuation
                didNotifyListenerStopped = false

                let timeoutNanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                startupTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    self?.completeStartupWaiter(result: .timedOut)
                }
                listener?.start(queue: networkQueue)
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.completeStartupWaiter(result: .failed(error: LifecycleError.listenerCancelled))
            }
        }
    }

    func listeningPort() -> UInt16? {
        listener?.port?.rawValue
    }

    func disconnectAllStreamClients() {
        for hub in liveHubs.values {
            hub.disconnectAllClients()
        }
        liveTargetByConnectionKey.removeAll()
        liveReceiveBufferByConnectionKey.removeAll()
    }

    var activeStreamClientCount: Int {
        liveHubs.values.reduce(0) { partialResult, hub in
            partialResult + hub.activeClientCount
        }
    }

    func streamClientCount(for target: ShareTarget) -> Int {
        liveHubs[target]?.activeClientCount ?? 0
    }

    func stopListener() {
        completeStartupWaiter(result: .failed(error: LifecycleError.listenerCancelled))
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
            notifyListenerStoppedIfNeeded()
            stopListener()
        case .cancelled:
            AppLog.web.info("Web listener cancelled.")
            completeStartupWaiter(result: .failed(error: LifecycleError.listenerCancelled))
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
            removeLiveClient(connection, cancelConnection: true)
        case .cancelled:
            let endpoint = Self.endpointDescription(for: connection)
            AppLog.web.debug("Connection cancelled [\(endpoint, privacy: .public)].")
            removeLiveClient(connection, cancelConnection: false)
        default:
            break
        }
    }

    private func removeLiveClient(_ connection: NWConnection, cancelConnection: Bool) {
        let key = connectionKey(for: connection)
        if let target = liveTargetByConnectionKey.removeValue(forKey: key),
           let hub = liveHubs[target] {
            hub.removeClient(connection)
        }
        liveReceiveBufferByConnectionKey.removeValue(forKey: key)
        if cancelConnection {
            connection.cancel()
        }
    }

    private func liveHub(for target: ShareTarget) -> LiveSocketHub? {
        if let existing = liveHubs[target] {
            return existing
        }
        guard let hub = liveHubProvider(target) else { return nil }
        liveHubs[target] = hub
        return hub
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
            .replacingOccurrences(of: "__LIVE_PATH__", with: target.livePath)
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
        case .openLiveSocket(let target):
            guard isValidWebSocketUpgrade(request.headers) else {
                sendResponseAndClose(
                    requestHandler.responseData(for: .badRequest),
                    on: connection,
                    failureContext: "Reject invalid websocket upgrade"
                )
                return
            }
            openLiveSocket(on: connection, target: target, headers: request.headers, initialBody: request.body)
        case .legacyStreamRemoved, .badRequest, .sharingUnavailable, .methodNotAllowed, .notFound:
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

    private func openLiveSocket(
        on connection: NWConnection,
        target: ShareTarget,
        headers: [String: String],
        initialBody: Data
    ) {
        guard let hub = liveHub(for: target),
              let acceptValue = makeWebSocketAcceptValue(headers: headers) else {
            sendResponseAndClose(
                requestHandler.responseData(for: .sharingUnavailable),
                on: connection,
                failureContext: "Reject missing live hub"
            )
            return
        }

        let response = Data(
            """
            HTTP/1.1 101 Switching Protocols\r
            Upgrade: websocket\r
            Connection: Upgrade\r
            Sec-WebSocket-Accept: \(acceptValue)\r
            \r
            """.utf8
        )
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    AppErrorMapper.logFailure("Send websocket upgrade response", error: error, logger: AppLog.web)
                    connection.cancel()
                    return
                }
                hub.addClient(connection)
                let key = self.connectionKey(for: connection)
                self.liveTargetByConnectionKey[key] = target
                self.liveReceiveBufferByConnectionKey[key] = initialBody
                self.receiveLiveSocketFrame(on: connection, key: key)
            }
        })
    }

    private func receiveLiveSocketFrame(on connection: NWConnection, key: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunkSize) { [weak self] content, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    Self.logConnectionIssue("Receive live socket frame", error: error)
                    self.removeLiveClient(connection, cancelConnection: true)
                    return
                }

                if let content, !content.isEmpty {
                    var buffer = self.liveReceiveBufferByConnectionKey[key] ?? Data()
                    buffer.append(content)
                    if buffer.count > Self.maxLiveSocketBufferBytes {
                        AppLog.web.debug("Disconnecting live socket client due to oversized receive buffer.")
                        self.removeLiveClient(connection, cancelConnection: true)
                        return
                    }
                    self.liveReceiveBufferByConnectionKey[key] = self.processLiveSocketBuffer(
                        buffer,
                        for: key,
                        connection: connection
                    )
                }

                if isComplete {
                    self.removeLiveClient(connection, cancelConnection: true)
                    return
                }

                guard self.liveTargetByConnectionKey[key] != nil else { return }
                self.receiveLiveSocketFrame(on: connection, key: key)
            }
        }
    }

    private func processLiveSocketBuffer(_ buffer: Data, for key: ObjectIdentifier, connection: NWConnection) -> Data {
        var remaining = buffer

        if remaining.count >= 1 {
            let firstByte = remaining[0]
            let isFin = (firstByte & 0x80) != 0
            let rsvBits = firstByte & 0x70
            if !isFin || rsvBits != 0 {
                AppLog.web.debug("Disconnecting live socket client due to unsupported websocket fragmentation/RSV bits.")
                removeLiveClient(connection, cancelConnection: true)
                return Data()
            }
        }

        if remaining.count >= 2 {
            let isMasked = (remaining[1] & 0x80) != 0
            if !isMasked {
                AppLog.web.debug("Disconnecting live socket client due to unmasked websocket frame.")
                removeLiveClient(connection, cancelConnection: true)
                return Data()
            }
        }

        while let frame = parseNextClientWebSocketFrame(from: remaining) {
            remaining.removeFirst(frame.totalLength)
            handleLiveSocketFrame(frame, connection: connection)
            if liveTargetByConnectionKey[key] == nil {
                return Data()
            }
        }
        return remaining
    }

    private func handleLiveSocketFrame(_ frame: ParsedClientWebSocketFrame, connection: NWConnection) {
        switch frame.opcode {
        case 0x8:
            if frame.payload.count > 125 {
                removeLiveClient(connection, cancelConnection: true)
                return
            }
            connection.send(content: makeWebSocketCloseFrame(frame.payload), completion: .contentProcessed { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.removeLiveClient(connection, cancelConnection: true)
                }
            })
        case 0x9:
            if frame.payload.count > 125 {
                removeLiveClient(connection, cancelConnection: true)
                return
            }
            connection.send(content: makeWebSocketPongFrame(frame.payload), completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    AppErrorMapper.logFailure("Send websocket pong", error: error, logger: AppLog.web)
                    self.removeLiveClient(connection, cancelConnection: true)
                }
            })
        default:
            break
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

private struct ParsedClientWebSocketFrame {
    let opcode: UInt8
    let payload: Data
    let totalLength: Int
}

private func parseNextClientWebSocketFrame(from buffer: Data) -> ParsedClientWebSocketFrame? {
    guard buffer.count >= 2 else { return nil }

    let opcode = buffer[0] & 0x0F
    let secondByte = buffer[1]
    guard (secondByte & 0x80) != 0 else { return nil } // Client frames must be masked.

    var cursor = 2
    let payloadLengthMarker = Int(secondByte & 0x7F)
    let payloadLength: Int
    switch payloadLengthMarker {
    case 126:
        guard buffer.count >= cursor + 2 else { return nil }
        payloadLength = buffer[cursor..<(cursor + 2)].reduce(0) { ($0 << 8) | Int($1) }
        cursor += 2
    case 127:
        guard buffer.count >= cursor + 8 else { return nil }
        payloadLength = buffer[cursor..<(cursor + 8)].reduce(0) { ($0 << 8) | Int($1) }
        cursor += 8
    default:
        payloadLength = payloadLengthMarker
    }

    let totalLength = cursor + 4 + payloadLength
    guard buffer.count >= totalLength else { return nil }

    let maskKey = Array(buffer[cursor..<(cursor + 4)])
    cursor += 4

    var payload = Data(buffer[cursor..<totalLength])
    if !payload.isEmpty {
        let payloadCount = payload.count
        payload.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in 0..<payloadCount {
                baseAddress[index] ^= maskKey[index % maskKey.count]
            }
        }
    }

    return ParsedClientWebSocketFrame(opcode: opcode, payload: payload, totalLength: totalLength)
}
