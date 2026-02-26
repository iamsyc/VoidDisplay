import Foundation
@testable import VoidDisplay

@MainActor
final class MockWebServiceController: WebServiceControllerProtocol {
    var portValue: UInt16 = 9090
    var currentServer: WebServer?
    var isRunning = false
    var activeStreamClientCount = 0
    var streamClientCountByTarget: [ShareTarget: Int] = [:]
    var onRunningStateChanged: (@MainActor @Sendable (Bool) -> Void)?

    var startResult: WebServiceStartResult = .started(
        WebServiceBinding(requestedPort: 9090, boundPort: 9090)
    )
    var lastRequestedPort: UInt16?
    var startCallCount = 0
    var stopCallCount = 0
    var disconnectCallCount = 0
    var capturedTargetStateProvider: (@MainActor @Sendable (ShareTarget) -> ShareTargetState)?
    var capturedFrameProvider: (@MainActor @Sendable (ShareTarget) -> Data?)?

    func start(
        requestedPort: UInt16,
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        frameProvider: @escaping @MainActor @Sendable (ShareTarget) -> Data?
    ) async -> WebServiceStartResult {
        startCallCount += 1
        lastRequestedPort = requestedPort
        capturedTargetStateProvider = targetStateProvider
        capturedFrameProvider = frameProvider
        switch startResult {
        case .started(let binding), .alreadyRunning(let binding):
            isRunning = true
            portValue = binding.boundPort
        case .failed:
            isRunning = false
        }
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
