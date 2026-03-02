import Foundation
@testable import VoidDisplay

@MainActor
final class MockWebServiceController: WebServiceControllerProtocol {
    var portValue: UInt16 = 9090
    var currentServer: WebServer?
    var lifecycleState: WebServiceLifecycleState = .stopped
    var isRunning = false
    var activeStreamClientCount = 0
    var streamClientCountByTarget: [ShareTarget: Int] = [:]
    var onRunningStateChanged: (@MainActor @Sendable (Bool) -> Void)?
    var onLifecycleStateChanged: (@MainActor @Sendable (WebServiceLifecycleState) -> Void)?

    var startResult: WebServiceStartResult = .started(
        WebServiceBinding(requestedPort: 9090, boundPort: 9090)
    )
    var lastRequestedPort: UInt16?
    var startCallCount = 0
    var stopCallCount = 0
    var disconnectCallCount = 0
    var capturedTargetStateProvider: (@MainActor @Sendable (ShareTarget) -> ShareTargetState)?
    var capturedSessionHubProvider: (@MainActor @Sendable (ShareTarget) -> WebRTCSessionHub?)?

    func start(
        requestedPort: UInt16,
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        sessionHubProvider: @escaping @MainActor @Sendable (ShareTarget) -> WebRTCSessionHub?
    ) async -> WebServiceStartResult {
        startCallCount += 1
        lastRequestedPort = requestedPort
        capturedTargetStateProvider = targetStateProvider
        capturedSessionHubProvider = sessionHubProvider
        switch startResult {
        case .started(let binding), .alreadyRunning(let binding):
            isRunning = true
            portValue = binding.boundPort
            lifecycleState = .running(binding)
        case .failed:
            isRunning = false
            lifecycleState = .failed(startResult.failure ?? .listenerFailed(port: requestedPort, message: "mock_failure"))
        }
        onRunningStateChanged?(isRunning)
        onLifecycleStateChanged?(lifecycleState)
        return startResult
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
        lifecycleState = .stopped
        onRunningStateChanged?(isRunning)
        onLifecycleStateChanged?(lifecycleState)
    }

    func disconnectAllStreamClients() {
        disconnectCallCount += 1
    }

    func streamClientCount(for target: ShareTarget) -> Int {
        streamClientCountByTarget[target] ?? 0
    }
}
