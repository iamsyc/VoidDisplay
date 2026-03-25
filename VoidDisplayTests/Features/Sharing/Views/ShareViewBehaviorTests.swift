import CoreGraphics
import ScreenCaptureKit
import Testing
@testable import VoidDisplay

private actor ShareViewLoaderGate {
    private var callCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func next() async {
        callCount += 1
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func currentCallCount() -> Int {
        callCount
    }
}

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
    var value: [CGDirectDisplayID]

    init(_ value: [CGDirectDisplayID]) {
        self.value = value
    }
}

private final class ShareViewMockSCDisplayBox: NSObject {
    @objc let displayID: CGDirectDisplayID
    @objc let width: Int
    @objc let height: Int
    @objc let frame: CGRect

    init(displayID: CGDirectDisplayID, width: Int, height: Int) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.frame = CGRect(x: 0, y: 0, width: width, height: height)
        super.init()
    }
}

private enum ShareViewMockSCDisplay {
    static func make(displayID: CGDirectDisplayID, width: Int, height: Int) -> SCDisplay {
        let box = ShareViewMockSCDisplayBox(displayID: displayID, width: width, height: height)
        return unsafeBitCast(box, to: SCDisplay.self)
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

    @Test func lifecycleHandleAppearRefreshesPermissionAndEnablesToolbarFallback() {
        let viewModel = makeViewModel(isWebServiceRunning: false)
        let monitor = ShareViewDisplayReconfigurationMonitor(startResults: [false])
        let lifecycle = ShareViewLifecycleController(
            displayRefreshMonitor: monitor,
            recoveryAttemptInterval: 99
        )

        lifecycle.handleAppear(viewModel: viewModel)

        #expect(viewModel.catalog.lastPreflightPermission == true)
        #expect(lifecycle.showToolbarRefresh)
        #expect(monitor.startCallCount == 1)
    }

    @Test func lifecycleFallbackRefreshesDisplaysAfterTopologyChange() async {
        let loaderGate = ShareViewLoaderGate()
        let signatureBox = ShareViewSignatureBox([101])
        let existingDisplay = ShareViewMockSCDisplay.make(displayID: 101, width: 1920, height: 1080)
        let refreshedDisplay = ShareViewMockSCDisplay.make(displayID: 202, width: 2560, height: 1440)
        let viewModel = makeViewModel(
            isWebServiceRunning: true,
            loadShareableDisplays: {
                await loaderGate.next()
                return [refreshedDisplay]
            },
            activeDisplayIDsProvider: { Set(signatureBox.value) }
        )
        viewModel.catalog.displays = [existingDisplay]
        viewModel.catalog.lastLoadedActiveDisplayTopologySignature = [101]

        let lifecycle = ShareViewLifecycleController(
            displayRefreshMonitor: ShareViewDisplayReconfigurationMonitor(startResults: [false, false]),
            displayTopologySignatureProvider: { signatureBox.value },
            fallbackPollingInterval: .milliseconds(20),
            recoveryAttemptInterval: 99
        )

        lifecycle.handleAppear(viewModel: viewModel)
        await drainMainActorTasks()
        #expect(await loaderGate.currentCallCount() == 0)

        signatureBox.value = [202]

        let requestedReload = await waitUntilAsync {
            await loaderGate.currentCallCount() == 1
        }
        #expect(requestedReload)

        await loaderGate.release()
        let finished = await waitUntil {
            viewModel.catalog.isLoadingDisplays == false &&
                viewModel.catalog.displays?.map(\.displayID) == [202]
        }
        #expect(finished)
    }

    @Test func lifecycleHandleDisappearCancelsInFlightLoadAndStopsMonitor() async {
        let loaderGate = ShareViewLoaderGate()
        let monitor = ShareViewDisplayReconfigurationMonitor(startResults: [true])
        let viewModel = makeViewModel(
            isWebServiceRunning: true,
            loadShareableDisplays: {
                await loaderGate.next()
                return [ShareViewMockSCDisplay.make(displayID: 303, width: 1280, height: 720)]
            }
        )
        let lifecycle = ShareViewLifecycleController(displayRefreshMonitor: monitor)

        viewModel.loadDisplays()
        #expect(await waitUntilAsync { await loaderGate.currentCallCount() == 1 })

        lifecycle.handleDisappear(viewModel: viewModel)
        await loaderGate.release()

        let cancelled = await waitUntil {
            viewModel.catalog.isLoadingDisplays == false && viewModel.catalog.displays == nil
        }
        #expect(cancelled)
        #expect(monitor.stopCallCount == 1)
    }

    @Test func viewModelSurfacesStartingStateFromSharingDependency() {
        let viewModel = makeViewModel(
            isWebServiceRunning: true,
            isStartingDisplayID: { $0 == 404 }
        )

        #expect(viewModel.isStarting(displayID: 404))
        #expect(viewModel.isStarting(displayID: 405) == false)
    }

    private func makeViewModel(
        isWebServiceRunning: Bool,
        isStartingDisplayID: @escaping @MainActor (CGDirectDisplayID) -> Bool = { _ in false },
        loadShareableDisplays: (@MainActor () async throws -> [SCDisplay])? = nil,
        activeDisplayIDsProvider: @escaping @MainActor () -> Set<CGDirectDisplayID> = { [] }
    ) -> ShareViewModel {
        ShareViewModel(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: loadShareableDisplays,
            activeDisplayIDsProvider: activeDisplayIDsProvider,
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { isWebServiceRunning },
                    isStartingDisplayID: isStartingDisplayID,
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
    }

    private func waitUntilAsync(
        timeoutNanoseconds: UInt64 = AsyncTestTimeouts.defaultAsyncAssertion,
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
