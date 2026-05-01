import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import Network
import OSLog
import Darwin
package enum WebServiceServerStopReason: Equatable {
    case requested
    case startupCancelled
    case superseded
    case listenerFailed
    case listenerCancelled

    package var isExpected: Bool {
        switch self {
        case .requested, .startupCancelled, .superseded:
            true
        case .listenerFailed, .listenerCancelled:
            false
        }
    }
}

@MainActor
package protocol WebServiceControllerProtocol: AnyObject {
    var portValue: UInt16 { get }
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
        concreteTargetResolver: @escaping @MainActor @Sendable (ShareTarget) -> ShareTarget?,
        sessionHubProvider: @escaping @MainActor @Sendable (ShareTarget) -> WebRTCSessionHub?,
        sharingEventSink: @escaping @Sendable (SharingSessionEvent) -> Void
    ) async -> WebServiceStartResult
    func stop()
    func disconnectAllStreamClients()
    func disconnectStreamClients(for targets: Set<ShareTarget>)
}

@MainActor
package protocol WebServiceServerProtocol: AnyObject {
    func startListener() async -> WebServer.ListenerStartResult
    func stopListener(reason: WebServiceServerStopReason)
    func disconnectAllStreamClients()
    func disconnectStreamClients(for targets: Set<ShareTarget>)
    var activeStreamClientCount: Int { get }
    func streamClientCount(for target: ShareTarget) -> Int
}

@MainActor
package extension WebServiceServerProtocol {
    func stopListener() {
        stopListener(reason: .requested)
    }
}

@MainActor
extension WebServer: WebServiceServerProtocol {
    package func startListener() async -> ListenerStartResult {
        await startListener(timeout: 1.5)
    }
}

@MainActor
package final class WebServiceController: WebServiceControllerProtocol {
    package typealias WebServiceServerFactory = @MainActor @Sendable (
        _ port: NWEndpoint.Port,
        _ targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        _ concreteTargetResolver: @escaping @MainActor @Sendable (ShareTarget) -> ShareTarget?,
        _ sessionHubProvider: @escaping @MainActor @Sendable (ShareTarget) -> WebRTCSessionHub?,
        _ sharingEventSink: @escaping @Sendable (SharingSessionEvent) -> Void,
        _ onListenerStopped: (@MainActor @Sendable (WebServiceServerStopReason) -> Void)?
    ) throws -> any WebServiceServerProtocol

    private var activeServer: (any WebServiceServerProtocol)?
    private var activeServerToken: UUID?
    private var startingServer: (token: UUID, server: any WebServiceServerProtocol)?
    private var startupTask: Task<WebServiceStartResult, Never>?
    private var currentBinding: WebServiceBinding?
    private var lastRequestedPort: UInt16 = 8089
    private var state: WebServiceLifecycleState = .stopped
    private var lifecycleNonce: UInt64 = 0
    private let webServiceServerFactory: WebServiceServerFactory

    package var onRunningStateChanged: (@MainActor @Sendable (Bool) -> Void)?
    package var onLifecycleStateChanged: (@MainActor @Sendable (WebServiceLifecycleState) -> Void)?

    package init(
        webServiceServerFactory: @escaping WebServiceServerFactory = {
            port,
            targetStateProvider,
            concreteTargetResolver,
            sessionHubProvider,
            sharingEventSink,
            onListenerStopped in
            try WebServer(
                using: port,
                targetStateProvider: targetStateProvider,
                concreteTargetResolver: concreteTargetResolver,
                sessionHubProvider: sessionHubProvider,
                sharingEventSink: sharingEventSink,
                onListenerStopped: onListenerStopped
            )
        }
    ) {
        self.webServiceServerFactory = webServiceServerFactory
    }

    package var portValue: UInt16 {
        switch state {
        case .running(let binding):
            return binding.boundPort
        case .starting(let requestedPort):
            return requestedPort
        default:
            return currentBinding?.boundPort ?? lastRequestedPort
        }
    }

    package var lifecycleState: WebServiceLifecycleState {
        state
    }

    package var isRunning: Bool {
        state.isRunning
    }

    package var activeStreamClientCount: Int {
        activeServer?.activeStreamClientCount ?? 0
    }

    package func streamClientCount(for target: ShareTarget) -> Int {
        activeServer?.streamClientCount(for: target) ?? 0
    }

    @discardableResult
    package func start(
        requestedPort: UInt16,
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        concreteTargetResolver: @escaping @MainActor @Sendable (ShareTarget) -> ShareTarget?,
        sessionHubProvider: @escaping @MainActor @Sendable (ShareTarget) -> WebRTCSessionHub?,
        sharingEventSink: @escaping @Sendable (SharingSessionEvent) -> Void
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
                concreteTargetResolver: concreteTargetResolver,
                sessionHubProvider: sessionHubProvider,
                sharingEventSink: sharingEventSink
            )
        }

        startupTask = task
        let result = await task.value
        if startupTask != nil {
            startupTask = nil
        }
        return result
    }

    package func stop() {
        guard activeServer != nil || startingServer != nil || startupTask != nil || state != .stopped else {
            AppLog.web.debug("Stop requested while web service is not running.")
            return
        }

        lifecycleNonce &+= 1
        setLifecycleState(.stopping)

        let runningServer = activeServer
        let startingServer = startingServer
        startupTask?.cancel()
        startupTask = nil
        self.startingServer = nil
        activeServerToken = nil
        activeServer = nil
        currentBinding = nil

        startingServer?.server.stopListener(reason: .requested)
        runningServer?.stopListener(reason: .requested)
        setLifecycleState(.stopped)
    }

    package func disconnectAllStreamClients() {
        activeServer?.disconnectAllStreamClients()
    }

    package func disconnectStreamClients(for targets: Set<ShareTarget>) {
        guard !targets.isEmpty else { return }
        activeServer?.disconnectStreamClients(for: targets)
    }

    private func startInternal(
        requestedPort: UInt16,
        operationNonce: UInt64,
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        concreteTargetResolver: @escaping @MainActor @Sendable (ShareTarget) -> ShareTarget?,
        sessionHubProvider: @escaping @MainActor @Sendable (ShareTarget) -> WebRTCSessionHub?,
        sharingEventSink: @escaping @Sendable (SharingSessionEvent) -> Void
    ) async -> WebServiceStartResult {
        lastRequestedPort = requestedPort

        guard isCurrentOperation(operationNonce) else {
            return supersededFailure(port: requestedPort)
        }

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

        do {
            let serverToken = UUID()
            let server = try webServiceServerFactory(
                port,
                targetStateProvider,
                concreteTargetResolver,
                sessionHubProvider,
                sharingEventSink,
                { [weak self] reason in
                    self?.handleServerStop(serverToken: serverToken, reason: reason)
                }
            )
            guard isCurrentOperation(operationNonce) else {
                server.stopListener(reason: .superseded)
                return supersededFailure(port: requestedPort)
            }

            startingServer = (serverToken, server)
            defer {
                if self.startingServer?.token == serverToken {
                    self.startingServer = nil
                }
            }

            let startResult = await server.startListener()
            let stillOwnsStartupSlot = startingServer?.token == serverToken
            guard isCurrentOperation(operationNonce), stillOwnsStartupSlot else {
                if stillOwnsStartupSlot {
                    server.stopListener(reason: .superseded)
                }
                return supersededFailure(port: requestedPort)
            }

            switch startResult {
            case .ready(let boundPort):
                activeServer = server
                activeServerToken = serverToken
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
                server.stopListener(reason: .requested)
                let failure: WebServiceStartFailure = .timedOut(port: requestedPort)
                setLifecycleState(.failed(failure))
                AppLog.web.error(
                    "Web service failed to become ready in time (requestedPort: \(requestedPort, privacy: .public))."
                )
                return .failed(failure)

            case .failed(let error):
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

    private func handleServerStop(serverToken: UUID, reason: WebServiceServerStopReason) {
        guard !reason.isExpected else {
            AppLog.web.debug("Ignoring expected web listener stop notification.")
            return
        }

        if activeServerToken == serverToken {
            AppLog.web.warning("Web listener stopped unexpectedly; transitioning web service state to failed.")
            clearRunningServerIfTokenMatches(serverToken)
            setLifecycleState(listenerStopFailure(for: reason))
            return
        }

        if startingServer?.token == serverToken {
            AppLog.web.debug("Observed startup listener stop before start task completed.")
        }
    }

    private func clearRunningServerIfTokenMatches(_ token: UUID?) {
        guard let token else { return }
        guard activeServerToken == token else { return }
        activeServer = nil
        activeServerToken = nil
        currentBinding = nil
    }

    private func isCurrentOperation(_ nonce: UInt64) -> Bool {
        lifecycleNonce == nonce
    }

    private func supersededFailure(port: UInt16) -> WebServiceStartResult {
        .failed(
            .listenerFailed(
                port: port,
                message: String(localized: "Web service startup was superseded.")
            )
        )
    }

    private func listenerStopFailure(for reason: WebServiceServerStopReason) -> WebServiceLifecycleState {
        let message: String
        switch reason {
        case .listenerFailed:
            message = String(localized: "Web listener stopped unexpectedly.")
        case .listenerCancelled:
            message = String(localized: "Web listener was cancelled unexpectedly.")
        case .requested, .startupCancelled, .superseded:
            message = String(localized: "Web listener stopped unexpectedly.")
        }
        return .failed(.listenerFailed(port: lastRequestedPort, message: message))
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

    package static func classifyStartFailure(error: Error, requestedPort: UInt16) -> WebServiceStartFailure {
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

    package static func preflightBindingFailure(for requestedPort: UInt16) -> WebServiceStartFailure? {
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
