import Foundation
import Network
import OSLog
import Darwin

@MainActor
protocol WebServiceControllerProtocol: AnyObject {
    var portValue: UInt16 { get }
    var currentServer: WebServer? { get }
    var lifecycleState: WebServiceLifecycleState { get }
    var isRunning: Bool { get }
    var activeStreamClientCount: Int { get }
    var onRunningStateChanged: (@MainActor @Sendable (Bool) -> Void)? { get set }
    var onLifecycleStateChanged: (@MainActor @Sendable (WebServiceLifecycleState) -> Void)? { get set }
    func streamClientCount(for target: ShareTarget) -> Int

    @discardableResult
    func start(
        requestedPort: UInt16,
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        sessionHubProvider: @escaping @MainActor @Sendable (ShareTarget) -> WebRTCSessionHub?
    ) async -> WebServiceStartResult
    func stop()
    func disconnectAllStreamClients()
}

@MainActor
protocol WebServiceServerProtocol: AnyObject {
    func startListener() async -> WebServer.ListenerStartResult
    func stopListener()
    func disconnectAllStreamClients()
    var activeStreamClientCount: Int { get }
    func streamClientCount(for target: ShareTarget) -> Int
}

@MainActor
extension WebServer: WebServiceServerProtocol {
    func startListener() async -> ListenerStartResult {
        await startListener(timeout: 1.5)
    }
}

@MainActor
final class WebServiceController: WebServiceControllerProtocol {
    typealias WebServiceServerFactory = @MainActor @Sendable (
        _ port: NWEndpoint.Port,
        _ targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        _ sessionHubProvider: @escaping @MainActor @Sendable (ShareTarget) -> WebRTCSessionHub?,
        _ onListenerStopped: (@MainActor @Sendable () -> Void)?
    ) throws -> any WebServiceServerProtocol

    private var activeServer: (any WebServiceServerProtocol)?
    private var webServer: WebServer?
    private var activeServerToken: UUID?
    private var startupTask: Task<WebServiceStartResult, Never>?
    private var currentBinding: WebServiceBinding?
    private var lastRequestedPort: UInt16 = 8081
    private var state: WebServiceLifecycleState = .stopped
    private var lifecycleNonce: UInt64 = 0
    private let webServiceServerFactory: WebServiceServerFactory

    var onRunningStateChanged: (@MainActor @Sendable (Bool) -> Void)?
    var onLifecycleStateChanged: (@MainActor @Sendable (WebServiceLifecycleState) -> Void)?

    init(
        webServiceServerFactory: @escaping WebServiceServerFactory = {
            port,
            targetStateProvider,
            sessionHubProvider,
            onListenerStopped in
            try WebServer(
                using: port,
                targetStateProvider: targetStateProvider,
                sessionHubProvider: sessionHubProvider,
                onListenerStopped: onListenerStopped
            )
        }
    ) {
        self.webServiceServerFactory = webServiceServerFactory
    }

    var portValue: UInt16 {
        switch state {
        case .running(let binding):
            return binding.boundPort
        case .starting(let requestedPort):
            return requestedPort
        default:
            return currentBinding?.boundPort ?? lastRequestedPort
        }
    }

    var currentServer: WebServer? {
        webServer
    }

    var lifecycleState: WebServiceLifecycleState {
        state
    }

    var isRunning: Bool {
        state.isRunning
    }

    var activeStreamClientCount: Int {
        activeServer?.activeStreamClientCount ?? 0
    }

    func streamClientCount(for target: ShareTarget) -> Int {
        activeServer?.streamClientCount(for: target) ?? 0
    }

    @discardableResult
    func start(
        requestedPort: UInt16,
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        sessionHubProvider: @escaping @MainActor @Sendable (ShareTarget) -> WebRTCSessionHub?
    ) async -> WebServiceStartResult {
        if case .running(let binding) = state, activeServer != nil {
            AppLog.web.debug("Start requested while web service is already running.")
            return .alreadyRunning(binding)
        }

        if let startupTask {
            return await startupTask.value
        }

        lifecycleNonce &+= 1
        let nonce = lifecycleNonce
        setLifecycleState(.starting(requestedPort: requestedPort))

        let task = Task<WebServiceStartResult, Never> { @MainActor [weak self] in
            guard let self else {
                return .failed(
                    .listenerFailed(
                        port: requestedPort,
                        message: String(localized: "Web service controller is unavailable.")
                    )
                )
            }

            return await self.startInternal(
                requestedPort: requestedPort,
                operationNonce: nonce,
                targetStateProvider: targetStateProvider,
                sessionHubProvider: sessionHubProvider
            )
        }

        startupTask = task
        let result = await task.value
        if startupTask != nil {
            startupTask = nil
        }
        return result
    }

    func stop() {
        guard activeServer != nil || startupTask != nil || state != .stopped else {
            AppLog.web.debug("Stop requested while web service is not running.")
            return
        }

        lifecycleNonce &+= 1
        setLifecycleState(.stopping)

        let runningServer = activeServer
        startupTask?.cancel()
        startupTask = nil
        activeServerToken = nil
        activeServer = nil
        webServer = nil
        currentBinding = nil

        runningServer?.stopListener()
        setLifecycleState(.stopped)
    }

    func disconnectAllStreamClients() {
        activeServer?.disconnectAllStreamClients()
    }

    private func startInternal(
        requestedPort: UInt16,
        operationNonce: UInt64,
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        sessionHubProvider: @escaping @MainActor @Sendable (ShareTarget) -> WebRTCSessionHub?
    ) async -> WebServiceStartResult {
        lastRequestedPort = requestedPort

        guard (1024...65535).contains(Int(requestedPort)),
              let port = NWEndpoint.Port(rawValue: requestedPort) else {
            let failure: WebServiceStartFailure = .invalidPort(.outOfRange)
            if isCurrentOperation(operationNonce) {
                setLifecycleState(.failed(failure))
            }
            return .failed(failure)
        }

        if let preflightFailure = Self.preflightBindingFailure(for: requestedPort) {
            AppLog.web.error(
                "Web service preflight failed (requestedPort: \(requestedPort, privacy: .public), reason: \(String(describing: preflightFailure), privacy: .public))."
            )
            if isCurrentOperation(operationNonce) {
                setLifecycleState(.failed(preflightFailure))
            }
            return .failed(preflightFailure)
        }

        if let staleServer = activeServer {
            staleServer.stopListener()
            activeServer = nil
            webServer = nil
            activeServerToken = nil
            currentBinding = nil
        }

        do {
            let serverToken = UUID()
            let server = try webServiceServerFactory(
                port,
                targetStateProvider,
                sessionHubProvider,
                { [weak self] in
                    self?.handleUnexpectedListenerStop(serverToken: serverToken)
                }
            )
            activeServer = server
            webServer = server as? WebServer
            activeServerToken = serverToken
            currentBinding = nil

            let startResult = await server.startListener()
            guard isCurrentOperation(operationNonce), activeServerToken == serverToken else {
                server.stopListener()
                return .failed(
                    .listenerFailed(
                        port: requestedPort,
                        message: String(localized: "Web service startup was superseded.")
                    )
                )
            }

            switch startResult {
            case .ready(let boundPort):
                let binding = WebServiceBinding(
                    requestedPort: requestedPort,
                    boundPort: boundPort
                )
                currentBinding = binding
                setLifecycleState(.running(binding))
                AppLog.web.info(
                    "Web service started (requestedPort: \(requestedPort, privacy: .public), boundPort: \(boundPort, privacy: .public))."
                )
                return .started(binding)

            case .timedOut:
                clearRunningServerIfTokenMatches(serverToken)
                let failure: WebServiceStartFailure = .timedOut(port: requestedPort)
                setLifecycleState(.failed(failure))
                AppLog.web.error(
                    "Web service failed to become ready in time (requestedPort: \(requestedPort, privacy: .public))."
                )
                return .failed(failure)

            case .failed(let error):
                clearRunningServerIfTokenMatches(serverToken)
                let failure = mapStartFailure(error: error, requestedPort: requestedPort)
                setLifecycleState(.failed(failure))
                AppLog.web.error(
                    "Web service listener failed (requestedPort: \(requestedPort, privacy: .public)): \(String(describing: error), privacy: .public)"
                )
                return .failed(failure)
            }
        } catch {
            clearRunningServerIfTokenMatches(activeServerToken)
            let failure = mapStartFailure(error: error, requestedPort: requestedPort)
            setLifecycleState(.failed(failure))
            AppErrorMapper.logFailure("Start web service", error: error, logger: AppLog.web)
            return .failed(failure)
        }
    }

    private func handleUnexpectedListenerStop(serverToken: UUID) {
        guard activeServerToken == serverToken else { return }

        AppLog.web.warning("Web listener stopped unexpectedly; transitioning web service state to failed.")
        clearRunningServerIfTokenMatches(serverToken)
        let failure = WebServiceStartFailure.listenerFailed(
            port: lastRequestedPort,
            message: String(localized: "Web listener stopped unexpectedly.")
        )
        setLifecycleState(.failed(failure))
    }

    private func clearRunningServerIfTokenMatches(_ token: UUID?) {
        guard let token else { return }
        guard activeServerToken == token else { return }
        activeServer = nil
        webServer = nil
        activeServerToken = nil
        currentBinding = nil
    }

    private func isCurrentOperation(_ nonce: UInt64) -> Bool {
        lifecycleNonce == nonce
    }

    private func setLifecycleState(_ next: WebServiceLifecycleState) {
        guard state != next else { return }
        let previousIsRunning = state.isRunning
        state = next
        onLifecycleStateChanged?(next)
        if previousIsRunning != next.isRunning {
            onRunningStateChanged?(next.isRunning)
        }
    }

    private func mapStartFailure(error: Error, requestedPort: UInt16) -> WebServiceStartFailure {
        Self.classifyStartFailure(error: error, requestedPort: requestedPort)
    }

    static func classifyStartFailure(error: Error, requestedPort: UInt16) -> WebServiceStartFailure {
        if let nwError = error as? NWError {
            switch nwError {
            case .posix(let code):
                if code == .EADDRINUSE {
                    return .portInUse(port: requestedPort)
                }
                if code == .EACCES {
                    return .permissionDenied(port: requestedPort)
                }
            default:
                break
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            if nsError.code == POSIXErrorCode.EADDRINUSE.rawValue {
                return .portInUse(port: requestedPort)
            }
            if nsError.code == POSIXErrorCode.EACCES.rawValue {
                return .permissionDenied(port: requestedPort)
            }
        }

        return .listenerFailed(
            port: requestedPort,
            message: String(localized: "Failed to start web service on port \(requestedPort).")
        )
    }

    static func preflightBindingFailure(for requestedPort: UInt16) -> WebServiceStartFailure? {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            return .listenerFailed(
                port: requestedPort,
                message: String(localized: "Failed to prepare web service socket for port \(requestedPort).")
            )
        }
        defer { close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requestedPort.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            if let code = POSIXErrorCode(rawValue: errno) {
                switch code {
                case .EADDRINUSE:
                    return .portInUse(port: requestedPort)
                case .EACCES:
                    return .permissionDenied(port: requestedPort)
                default:
                    return .listenerFailed(
                        port: requestedPort,
                        message: String(localized: "Failed to start web service on port \(requestedPort).")
                    )
                }
            }
            return .listenerFailed(
                port: requestedPort,
                message: String(localized: "Failed to start web service on port \(requestedPort).")
            )
        }

        return nil
    }
}
