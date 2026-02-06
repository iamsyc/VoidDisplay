import Foundation
@testable import FreelyDisplay

@MainActor
final class MockWebServiceController: WebServiceControlling {
    var portValue: UInt16 = 9090
    var currentServer: WebServer?
    var isRunning = false

    var startResult = true
    var startCallCount = 0
    var stopCallCount = 0
    var disconnectCallCount = 0
    var capturedIsSharingProvider: (@MainActor @Sendable () -> Bool)?
    var capturedFrameProvider: (@MainActor @Sendable () -> Data?)?

    func start(
        isSharingProvider: @escaping @MainActor @Sendable () -> Bool,
        frameProvider: @escaping @MainActor @Sendable () -> Data?
    ) -> Bool {
        startCallCount += 1
        capturedIsSharingProvider = isSharingProvider
        capturedFrameProvider = frameProvider
        isRunning = startResult
        return startResult
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
    }

    func disconnectAllStreamClients() {
        disconnectCallCount += 1
    }
}
