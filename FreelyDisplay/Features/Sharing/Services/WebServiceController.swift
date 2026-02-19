import Foundation
import Network
import OSLog

@MainActor
protocol WebServiceControlling: AnyObject {
    var portValue: UInt16 { get }
    var currentServer: WebServer? { get }
    var isRunning: Bool { get }
    var activeStreamClientCount: Int { get }
    var onRunningStateChanged: (@MainActor @Sendable (Bool) -> Void)? { get set }
    func streamClientCount(for target: ShareTarget) -> Int

    @discardableResult
    func start(
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        frameProvider: @escaping @MainActor @Sendable (ShareTarget) -> Data?
    ) async -> Bool
    func stop()
    func disconnectAllStreamClients()
}

@MainActor
final class WebServiceController: WebServiceControlling {
    private let port: NWEndpoint.Port
    private var webServer: WebServer? = nil
    private var activeServerToken: UUID?
    private var startupTask: Task<Bool, Never>?
    private var listenerReady = false
    var onRunningStateChanged: (@MainActor @Sendable (Bool) -> Void)?

    init(port: NWEndpoint.Port = 8081) {
        self.port = port
    }

    var portValue: UInt16 {
        port.rawValue
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
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        frameProvider: @escaping @MainActor @Sendable (ShareTarget) -> Data?
    ) async -> Bool {
        if let startupTask {
            return await startupTask.value
        }

        if listenerReady, webServer != nil {
            AppLog.web.debug("Start requested while web service is already running.")
            return true
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.startInternal(
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
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        frameProvider: @escaping @MainActor @Sendable (ShareTarget) -> Data?
    ) async -> Bool {
        if webServer != nil {
            AppLog.web.warning("Start requested with stale server state; resetting before restart.")
            webServer?.stopListener()
            webServer = nil
            activeServerToken = nil
            listenerReady = false
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
                    self.onRunningStateChanged?(false)
                }
            )
            webServer = server
            activeServerToken = serverToken
            listenerReady = false

            let ready = await server.startListener()
            guard ready else {
                AppLog.web.error("Web service failed to become ready in time.")
                if activeServerToken == serverToken {
                    webServer = nil
                    activeServerToken = nil
                    listenerReady = false
                }
                onRunningStateChanged?(false)
                return false
            }

            guard activeServerToken == serverToken else {
                return false
            }
            listenerReady = true
            onRunningStateChanged?(true)
            AppLog.web.info("Web service started on port \(self.port.rawValue, privacy: .public).")
            return true
        } catch {
            AppErrorMapper.logFailure("Start web service", error: error, logger: AppLog.web)
            webServer = nil
            activeServerToken = nil
            listenerReady = false
            onRunningStateChanged?(false)
            return false
        }
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
        if previousToken != nil {
            onRunningStateChanged?(false)
        }
    }

    func disconnectAllStreamClients() {
        webServer?.disconnectAllStreamClients()
    }
}
