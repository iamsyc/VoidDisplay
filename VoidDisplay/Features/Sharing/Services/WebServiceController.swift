import Foundation
import Network
import OSLog
import Darwin

@MainActor
protocol WebServiceControllerProtocol: AnyObject {
    var portValue: UInt16 { get }
    var currentServer: WebServer? { get }
    var isRunning: Bool { get }
    var activeStreamClientCount: Int { get }
    var onRunningStateChanged: (@MainActor @Sendable (Bool) -> Void)? { get set }
    func streamClientCount(for target: ShareTarget) -> Int

    @discardableResult
    func start(
        requestedPort: UInt16,
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        frameProvider: @escaping @MainActor @Sendable (ShareTarget) -> Data?
    ) async -> WebServiceStartResult
    func stop()
    func disconnectAllStreamClients()
}

@MainActor
final class WebServiceController: WebServiceControllerProtocol {
    private var webServer: WebServer? = nil
    private var activeServerToken: UUID?
    private var startupTask: Task<WebServiceStartResult, Never>?
    private var listenerReady = false
    private var currentBinding: WebServiceBinding?
    private var lastRequestedPort: UInt16 = 8081
    var onRunningStateChanged: (@MainActor @Sendable (Bool) -> Void)?

    init() {}

    var portValue: UInt16 {
        currentBinding?.boundPort ?? lastRequestedPort
    }

    var currentServer: WebServer? {
        webServer
    }

    var isRunning: Bool {
        listenerReady
    }

    var activeStreamClientCount: Int {
        webServer?.activeStreamClientCount ?? 0
    }

    func streamClientCount(for target: ShareTarget) -> Int {
        webServer?.streamClientCount(for: target) ?? 0
    }

    @discardableResult
    func start(
        requestedPort: UInt16,
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        frameProvider: @escaping @MainActor @Sendable (ShareTarget) -> Data?
    ) async -> WebServiceStartResult {
        if let startupTask {
            return await startupTask.value
        }

        if listenerReady, webServer != nil, let binding = currentBinding {
            AppLog.web.debug("Start requested while web service is already running.")
            return .alreadyRunning(binding)
        }

        let task: Task<WebServiceStartResult, Never> = Task { @MainActor [weak self] in
            guard let self else {
                return WebServiceStartResult.failed(
                    .listenerFailed(
                        port: requestedPort,
                        message: String(localized: "Web service controller is unavailable.")
                    )
                )
            }
            return await self.startInternal(
                requestedPort: requestedPort,
                targetStateProvider: targetStateProvider,
                frameProvider: frameProvider
            )
        }
        startupTask = task
        let result = await task.value
        startupTask = nil
        return result
    }

    private func startInternal(
        requestedPort: UInt16,
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        frameProvider: @escaping @MainActor @Sendable (ShareTarget) -> Data?
    ) async -> WebServiceStartResult {
        lastRequestedPort = requestedPort

        guard (1024...65535).contains(Int(requestedPort)),
              let port = NWEndpoint.Port(rawValue: requestedPort) else {
            return .failed(.invalidPort(.outOfRange))
        }

        if let preflightFailure = Self.preflightBindingFailure(for: requestedPort) {
            AppLog.web.error(
                "Web service preflight failed (requestedPort: \(requestedPort, privacy: .public), reason: \(String(describing: preflightFailure), privacy: .public))."
            )
            return .failed(preflightFailure)
        }

        if webServer != nil {
            AppLog.web.warning("Start requested with stale server state; resetting before restart.")
            webServer?.stopListener()
            webServer = nil
            activeServerToken = nil
            listenerReady = false
            currentBinding = nil
        }

        do {
            let serverToken = UUID()
            let server = try WebServer(
                using: port,
                targetStateProvider: targetStateProvider,
                frameProvider: frameProvider,
                onListenerStopped: { [weak self] in
                    guard let self else { return }
                    guard self.activeServerToken == serverToken else { return }
                    AppLog.web.warning("Web listener stopped unexpectedly; clearing web service running state.")
                    self.listenerReady = false
                    self.webServer = nil
                    self.activeServerToken = nil
                    self.currentBinding = nil
                    self.onRunningStateChanged?(false)
                }
            )
            webServer = server
            activeServerToken = serverToken
            listenerReady = false
            currentBinding = nil

            let startResult = await server.startListener()
            switch startResult {
            case .ready(let boundPort):
                guard activeServerToken == serverToken else {
                    return .failed(.listenerFailed(port: requestedPort, message: String(localized: "Web service startup was superseded.")))
                }
                listenerReady = true
                let binding = WebServiceBinding(
                    requestedPort: requestedPort,
                    boundPort: boundPort
                )
                currentBinding = binding
                onRunningStateChanged?(true)
                AppLog.web.info(
                    "Web service started (requestedPort: \(requestedPort, privacy: .public), boundPort: \(boundPort, privacy: .public))."
                )
                return .started(binding)
            case .timedOut:
                AppLog.web.error(
                    "Web service failed to become ready in time (requestedPort: \(requestedPort, privacy: .public))."
                )
                if activeServerToken == serverToken {
                    webServer = nil
                    activeServerToken = nil
                    listenerReady = false
                    currentBinding = nil
                }
                onRunningStateChanged?(false)
                return .failed(.timedOut(port: requestedPort))
            case .failed(let error):
                if activeServerToken == serverToken {
                    webServer = nil
                    activeServerToken = nil
                    listenerReady = false
                    currentBinding = nil
                }
                onRunningStateChanged?(false)
                let failure = mapStartFailure(error: error, requestedPort: requestedPort)
                AppLog.web.error(
                    "Web service listener failed (requestedPort: \(requestedPort, privacy: .public)): \(String(describing: error), privacy: .public)"
                )
                return .failed(failure)
            }
        } catch {
            AppErrorMapper.logFailure("Start web service", error: error, logger: AppLog.web)
            webServer = nil
            activeServerToken = nil
            listenerReady = false
            currentBinding = nil
            onRunningStateChanged?(false)
            return .failed(mapStartFailure(error: error, requestedPort: requestedPort))
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

    func stop() {
        guard let runningServer = webServer else {
            AppLog.web.debug("Stop requested while web service is not running.")
            return
        }
        AppLog.web.info("Stopping web service.")
        let previousToken = activeServerToken
        activeServerToken = nil
        startupTask?.cancel()
        startupTask = nil
        listenerReady = false
        runningServer.stopListener()
        webServer = nil
        currentBinding = nil
        if previousToken != nil {
            onRunningStateChanged?(false)
        }
    }

    func disconnectAllStreamClients() {
        webServer?.disconnectAllStreamClients()
    }
}
