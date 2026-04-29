@testable import VoidDisplayFoundation
@testable import VoidDisplaySharing
import CoreGraphics
import Synchronization
import Testing

private final class ShareViewDisplayReconfigurationMonitor: DisplayReconfigurationMonitoring {
    private let startResults: [Bool]
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private var handler: (@MainActor () -> Void)?

    init(startResults: [Bool]) {
        self.startResults = startResults
    }

    @discardableResult
    func start(handler: @escaping @MainActor () -> Void) -> Bool {
        self.handler = handler
        let index = startCallCount
        startCallCount += 1
        if startResults.indices.contains(index) {
            return startResults[index]
        }
        return startResults.last ?? true
    }

    func stop() {
        stopCallCount += 1
        handler = nil
    }
}

private final class ShareViewSignatureBox {
    var value: ScreenCaptureDisplayTopologySignature

    init(_ value: ScreenCaptureDisplayTopologySignature) {
        self.value = value
    }
}

private final class ShareViewTopologyChangeCounter: @unchecked Sendable {
    private let count = Mutex(0)

    nonisolated func increment() {
        count.withLock { $0 += 1 }
    }

    nonisolated func snapshot() -> Int {
        count.withLock { $0 }
    }
}

@Suite(.serialized)
@MainActor
struct ShareViewBehaviorTests {
    @Test func contentResolverReturnsServiceStoppedForGrantedPermission() {
        let catalog = ScreenCaptureDisplayCatalogState()
        catalog.hasScreenCapturePermission = true

        let state = ShareViewContentResolver.resolve(
            catalog: catalog,
            isWebServiceRunning: false,
            visibleDisplayCount: 0
        )

        #expect(state == .serviceStopped)
    }

    @Test func lifecycleHandleAppearEnablesToolbarFallbackWhenMonitorRegistrationFails() {
        let monitor = ShareViewDisplayReconfigurationMonitor(startResults: [false])
        let lifecycle = DisplayTopologyRefreshLifecycleController(
            displayRefreshMonitor: monitor,
            recoveryAttemptInterval: 99
        )

        lifecycle.handleAppear {}

        #expect(lifecycle.showToolbarRefresh)
        #expect(monitor.startCallCount == 1)
    }

    @Test func lifecycleHandleDisappearStopsMonitor() {
        let monitor = ShareViewDisplayReconfigurationMonitor(startResults: [true])
        let lifecycle = DisplayTopologyRefreshLifecycleController(displayRefreshMonitor: monitor)

        lifecycle.handleAppear {}
        lifecycle.handleDisappear()

        #expect(monitor.stopCallCount == 1)
    }

    @Test func lifecycleFallbackDetectsConfigurationChangeForSameDisplayID() async {
        let displayID = CGDirectDisplayID(707)
        let signatureBox = ShareViewSignatureBox([
            ScreenCaptureDisplayTopologySignatureEntry(
                displayID: displayID,
                pixelWidth: 1920,
                pixelHeight: 1080
            )
        ])
        let lifecycle = DisplayTopologyRefreshLifecycleController(
            displayRefreshMonitor: ShareViewDisplayReconfigurationMonitor(startResults: [false, false]),
            displayTopologySignatureProvider: { signatureBox.value },
            fallbackPollingInterval: .milliseconds(20),
            recoveryAttemptInterval: 99
        )
        let topologyChangeCount = ShareViewTopologyChangeCounter()

        lifecycle.handleAppear {
            topologyChangeCount.increment()
        }
        signatureBox.value = [
            ScreenCaptureDisplayTopologySignatureEntry(
                displayID: displayID,
                pixelWidth: 2560,
                pixelHeight: 1440
            )
        ]

        #expect(await waitUntilAsync { topologyChangeCount.snapshot() == 1 })
        lifecycle.handleDisappear()
    }

    @Test func viewModelSurfacesStartingStateFromSharingDependency() {
        let viewModel = ShareViewModel(
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { true },
                    activeSharingDisplayCount: { 0 },
                    sharingClientCount: { 0 },
                    isDisplaySharing: { _ in false },
                    isStartingDisplayID: { $0 == 404 },
                    displayClientCount: { _ in 0 },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081)) },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in },
                    beginSharing: { _ in .started(()) },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )

        #expect(viewModel.isStarting(displayID: 404))
        #expect(viewModel.isStarting(displayID: 405) == false)
    }

    private func waitUntilAsync(
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        pollNanoseconds: UInt64 = 10_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .nanoseconds(pollNanoseconds))
        }
        return await condition()
    }
}
