import Foundation
import Network
import OSLog

@MainActor
protocol WebServiceControlling: AnyObject {
    var portValue: UInt16 { get }
    var currentServer: WebServer? { get }
    var isRunning: Bool { get }

    @discardableResult
    func start(
        isSharingProvider: @escaping @MainActor @Sendable () -> Bool,
        frameProvider: @escaping @MainActor @Sendable () -> Data?
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

    @discardableResult
    func start(
        isSharingProvider: @escaping @MainActor @Sendable () -> Bool,
        frameProvider: @escaping @MainActor @Sendable () -> Data?
    ) -> Bool {
        guard webServer == nil else {
            AppLog.web.debug("Start requested while web service is already running.")
            return true
        }

        do {
            webServer = try WebServer(
                using: port,
                isSharingProvider: isSharingProvider,
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
        AppLog.web.info("Stopping web service.")
        webServer?.stopListener()
        webServer = nil
    }

    func disconnectAllStreamClients() {
        webServer?.disconnectAllStreamClients()
    }
}
