import VoidDisplaySharing
import VoidDisplayFoundation
import Foundation

@MainActor
package final class MockWebServiceController: WebServiceControllerProtocol {
    package var portValue: UInt16 = 9090
    package var lifecycleState: WebServiceLifecycleState = .stopped
    package var isRunning = false
    package var activeStreamClientCount = 0
    package var streamClientCountByTarget: [ShareTarget: Int] = [:]
    package var onRunningStateChanged: (@MainActor @Sendable (Bool) -> Void)?
    package var onLifecycleStateChanged: (@MainActor @Sendable (WebServiceLifecycleState) -> Void)?

    package var startResult: WebServiceStartResult = .started(
        WebServiceBinding(requestedPort: 9090, boundPort: 9090)
    )
    package var lastRequestedPort: UInt16?
    package var startCallCount = 0
    package var stopCallCount = 0
    package var disconnectCallCount = 0
    package var disconnectTargetCallCount = 0
    package var disconnectedTargetsHistory: [Set<ShareTarget>] = []
    package var capturedTargetStateProvider: (@MainActor @Sendable (ShareTarget) -> ShareTargetState)?
    package var capturedConcreteTargetResolver: (@MainActor @Sendable (ShareTarget) -> ShareTarget?)?
    package var capturedSessionHubProvider: (@MainActor @Sendable (ShareTarget) -> (any SignalSessionHub)?)?
    package var capturedSharingEventSink: (@Sendable (SharingSessionEvent) -> Void)?

    package init() {}

    package func start(
        requestedPort: UInt16,
        targetStateProvider: @escaping @MainActor @Sendable (ShareTarget) -> ShareTargetState,
        concreteTargetResolver: @escaping @MainActor @Sendable (ShareTarget) -> ShareTarget?,
        sessionHubProvider: @escaping @MainActor @Sendable (ShareTarget) -> (any SignalSessionHub)?,
        sharingEventSink: @escaping @Sendable (SharingSessionEvent) -> Void
    ) async -> WebServiceStartResult {
        startCallCount += 1
        lastRequestedPort = requestedPort
        capturedTargetStateProvider = targetStateProvider
        capturedConcreteTargetResolver = concreteTargetResolver
        capturedSessionHubProvider = sessionHubProvider
        capturedSharingEventSink = sharingEventSink
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

    package func stop() {
        stopCallCount += 1
        isRunning = false
        lifecycleState = .stopped
        onRunningStateChanged?(isRunning)
        onLifecycleStateChanged?(lifecycleState)
    }

    package func disconnectAllStreamClients() {
        disconnectCallCount += 1
    }

    package func disconnectStreamClients(for targets: Set<ShareTarget>) {
        disconnectTargetCallCount += 1
        disconnectedTargetsHistory.append(targets)
    }

    package func streamClientCount(for target: ShareTarget) -> Int {
        streamClientCountByTarget[target] ?? 0
    }
}
