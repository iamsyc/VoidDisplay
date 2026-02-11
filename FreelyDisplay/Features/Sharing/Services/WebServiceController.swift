import Foundation
import Network
import OSLog

@MainActor
protocol WebServiceControlling: AnyObject {
    var portValue: UInt16 { get }
    var currentServer: WebServer? { get }
    var isRunning: Bool { get }
    var activeStreamClientCount: Int { get }
    func streamClientCount(for target: ShareTarget) -> Int

    @discardableResult
    func start(
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        frameProvider: @escaping @MainActor @Sendable (ShareTarget) -> Data?
    ) -> Bool
    func stop()
    func disconnectAllStreamClients()
}

@MainActor
final class WebServiceController: WebServiceControlling {
    private let port: NWEndpoint.Port
    private var webServer: WebServer? = nil

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
        webServer != nil
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
    ) -> Bool {
        guard webServer == nil else {
            AppLog.web.debug("Start requested while web service is already running.")
            return true
        }

        do {
            webServer = try WebServer(
                using: port,
                targetStateProvider: targetStateProvider,
                frameProvider: frameProvider
            )
            webServer?.startListener()
            AppLog.web.info("Web service started on port \(self.port.rawValue, privacy: .public).")
            return true
        } catch {
            AppErrorMapper.logFailure("Start web service", error: error, logger: AppLog.web)
            webServer = nil
            return false
        }
    }

    func stop() {
        guard let runningServer = webServer else {
            AppLog.web.debug("Stop requested while web service is not running.")
            return
        }
        AppLog.web.info("Stopping web service.")
        runningServer.stopListener()
        webServer = nil
    }

    func disconnectAllStreamClients() {
        webServer?.disconnectAllStreamClients()
    }
}
