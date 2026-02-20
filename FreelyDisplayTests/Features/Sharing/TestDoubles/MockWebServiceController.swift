import Foundation
@testable import FreelyDisplay

@MainActor
final class MockWebServiceController: WebServiceControllerProtocol {
    var portValue: UInt16 = 9090
    var currentServer: WebServer?
    var isRunning = false
    var activeStreamClientCount = 0
    var streamClientCountByTarget: [ShareTarget: Int] = [:]
    var onRunningStateChanged: (@MainActor @Sendable (Bool) -> Void)?

    var startResult = true
    var startCallCount = 0
    var stopCallCount = 0
    var disconnectCallCount = 0
    var capturedTargetStateProvider: (@MainActor @Sendable (ShareTarget) -> ShareTargetState)?
    var capturedFrameProvider: (@MainActor @Sendable (ShareTarget) -> Data?)?

    func start(
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        frameProvider: @escaping @MainActor @Sendable (ShareTarget) -> Data?
    ) async -> Bool {
        startCallCount += 1
        capturedTargetStateProvider = targetStateProvider
        capturedFrameProvider = frameProvider
        isRunning = startResult
        onRunningStateChanged?(isRunning)
        return startResult
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
        onRunningStateChanged?(isRunning)
    }

    func disconnectAllStreamClients() {
        disconnectCallCount += 1
    }

    func streamClientCount(for target: ShareTarget) -> Int {
        streamClientCountByTarget[target] ?? 0
    }
}
