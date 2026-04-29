@testable import VoidDisplayApp
@testable import VoidDisplayApp
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayCapture
@testable import VoidDisplaySharing
@testable import VoidDisplayObservability
@testable import VoidDisplaySupport
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing

private final class ScreenCatalogOrchestratorMockSCDisplayBox: NSObject {
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

private enum ScreenCatalogOrchestratorMockSCDisplay {
    static func make(displayID: CGDirectDisplayID, width: Int, height: Int) -> SCDisplay {
        let box = ScreenCatalogOrchestratorMockSCDisplayBox(
            displayID: displayID,
            width: width,
            height: height
        )
        return unsafeBitCast(box, to: SCDisplay.self)
    }
}

private actor ScreenCatalogOrchestratorLoadGate {
    private var displaysByCall: [[SendableDisplay]]
    private var callCount = 0
    private var continuations: [Int: CheckedContinuation<[SendableDisplay], Never>] = [:]

    init(displaysByCall: [[SendableDisplay]]) {
        self.displaysByCall = displaysByCall
    }

    func waitForNextDisplays() async -> [SendableDisplay] {
        callCount += 1
        let currentCall = callCount
        return await withCheckedContinuation { continuation in
            continuations[currentCall] = continuation
        }
    }

    func release(call: Int) {
        guard let continuation = continuations.removeValue(forKey: call) else { return }
        let displays = displaysByCall.indices.contains(call - 1) ? displaysByCall[call - 1] : []
        continuation.resume(returning: displays)
    }

    func currentCallCount() -> Int {
        callCount
    }
}

@MainActor
private final class ScreenCatalogOrchestratorActiveDisplayIDsBox {
    var ids: Set<CGDirectDisplayID>

    init(ids: Set<CGDirectDisplayID>) {
        self.ids = ids
    }
}

@Suite(.serialized)
@MainActor
struct ScreenCatalogOrchestratorTests {
    private final class OrchestratorPortPreferences: SharingPortPreferencesProtocol {
        var preferredPort: UInt16 = 8081

        func savePreferredPort(_ port: UInt16) {
            preferredPort = port
        }
    }

    @Test func captureAppearRefreshesAndConvergesVisibleDisplays() async {
        let removedDisplayID = CGDirectDisplayID(1001)
        let keptDisplayID = CGDirectDisplayID(1002)
        let removedDisplay = ScreenCatalogOrchestratorMockSCDisplay.make(
            displayID: removedDisplayID,
            width: 1920,
            height: 1080
        )
        let keptDisplay = ScreenCatalogOrchestratorMockSCDisplay.make(
            displayID: keptDisplayID,
            width: 2560,
            height: 1440
        )

        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: { [removedDisplay, keptDisplay] },
            activeDisplayIDsProvider: { [keptDisplayID] }
        )

        let sharingService = MockSharingService()
        sharingService.isWebServiceRunning = true
        sharingService.webServiceLifecycleState = .running(.init(requestedPort: 8081, boundPort: 8081))
        sharingService.activeSharingDisplayIDs = [removedDisplayID, keptDisplayID]
        sharingService.hasAnyActiveSharing = true
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: OrchestratorPortPreferences(),
            catalogService: catalogService
        )

        let captureService = MockCaptureMonitoringService()
        captureService.currentSessions = [
            makeSession(id: UUID(), displayID: removedDisplayID),
            makeSession(id: UUID(), displayID: keptDisplayID),
        ]
        let captureController = CaptureController(
            captureMonitoringService: captureService,
            catalogService: catalogService
        )
        let virtualDisplay = makeVirtualDisplayController()
        let orchestrator = ScreenCatalogOrchestrator(
            catalogService: catalogService,
            capture: captureController,
            sharing: sharingController,
            virtualDisplay: virtualDisplay
        )

        await orchestrator.handleAppear(source: .capturePage)

        #expect(catalogService.store.displays?.map(\.displayID) == [removedDisplayID, keptDisplayID])
        #expect(sharingService.registeredShareableDisplays.map(\.displayID) == [keptDisplayID])
        #expect(sharingService.stopSharingCallCount == 1)
        #expect(sharingService.activeSharingDisplayIDs == [keptDisplayID])
        #expect(captureService.removedDisplayIDs == [removedDisplayID])
    }

    @Test func sharingAppearWithStoppedServiceCancelsRefreshWithoutClearingSnapshot() async {
        let display = ScreenCatalogOrchestratorMockSCDisplay.make(
            displayID: 2001,
            width: 1920,
            height: 1080
        )
        let loadGate = ScreenCatalogOrchestratorLoadGate(displaysByCall: [[SendableDisplay(display)]])
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: {
                await loadGate.waitForNextDisplays().map(\.value)
            },
            activeDisplayIDsProvider: { [display.displayID] }
        )
        catalogService.store.hasScreenCapturePermission = true
        catalogService.store.displays = [display]
        catalogService.store.lastLoadedActiveDisplayTopologySignature = makeTestDisplayTopologySignature(
            [display.displayID]
        )

        let sharingController = SharingController(
            sharingService: MockSharingService(),
            portPreferences: OrchestratorPortPreferences(),
            catalogService: catalogService
        )
        let orchestrator = ScreenCatalogOrchestrator(
            catalogService: catalogService,
            capture: CaptureController(
                captureMonitoringService: MockCaptureMonitoringService(),
                catalogService: catalogService
            ),
            sharing: sharingController,
            virtualDisplay: makeVirtualDisplayController()
        )

        await orchestrator.handleAppear(source: .sharingPage)

        #expect(catalogService.store.isLoadingDisplays == false)
        #expect(catalogService.store.displays?.map(\.displayID) == [display.displayID])
        #expect(await loadGate.currentCallCount() == 0)
    }

    @Test func sharingServiceStartReplaysRegistrationWhenSnapshotIsReused() async {
        let display = ScreenCatalogOrchestratorMockSCDisplay.make(
            displayID: 3001,
            width: 2560,
            height: 1440
        )
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: {
                Issue.record("Expected cached snapshot reuse without a fresh load.")
                return []
            },
            activeDisplayIDsProvider: { [display.displayID] }
        )
        catalogService.store.hasScreenCapturePermission = true
        catalogService.store.displays = [display]
        catalogService.store.lastLoadedActiveDisplayTopologySignature = makeTestDisplayTopologySignature(
            [display.displayID]
        )

        let sharingService = MockSharingService()
        sharingService.isWebServiceRunning = true
        sharingService.webServiceLifecycleState = .running(.init(requestedPort: 8081, boundPort: 8081))
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: OrchestratorPortPreferences(),
            catalogService: catalogService
        )
        let orchestrator = ScreenCatalogOrchestrator(
            catalogService: catalogService,
            capture: CaptureController(
                captureMonitoringService: MockCaptureMonitoringService(),
                catalogService: catalogService
            ),
            sharing: sharingController,
            virtualDisplay: makeVirtualDisplayController()
        )

        await orchestrator.handleSharingServiceStateChanged(isRunning: true)

        #expect(catalogService.store.lastRefreshResult == .reusedSnapshot)
        #expect(sharingService.registerShareableDisplaysCallCount == 1)
        #expect(sharingService.registeredShareableDisplays.map(\.displayID) == [display.displayID])
    }

    @Test func permissionDeniedClearsSnapshotAndStopsInvalidSessions() async {
        let removedDisplayID = CGDirectDisplayID(4001)
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: false,
                requestResult: false
            ),
            loadShareableDisplays: {
                Issue.record("Display load should not run when permission is denied.")
                return []
            },
            activeDisplayIDsProvider: { [removedDisplayID] }
        )
        catalogService.store.displays = [
            ScreenCatalogOrchestratorMockSCDisplay.make(displayID: removedDisplayID, width: 1920, height: 1080)
        ]

        let sharingService = MockSharingService()
        sharingService.isWebServiceRunning = true
        sharingService.webServiceLifecycleState = .running(.init(requestedPort: 8081, boundPort: 8081))
        sharingService.activeSharingDisplayIDs = [removedDisplayID]
        sharingService.hasAnyActiveSharing = true
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: OrchestratorPortPreferences(),
            catalogService: catalogService
        )
        let captureService = MockCaptureMonitoringService()
        captureService.currentSessions = [
            makeSession(id: UUID(), displayID: removedDisplayID)
        ]
        let captureController = CaptureController(
            captureMonitoringService: captureService,
            catalogService: catalogService
        )
        let orchestrator = ScreenCatalogOrchestrator(
            catalogService: catalogService,
            capture: captureController,
            sharing: sharingController,
            virtualDisplay: makeVirtualDisplayController()
        )

        await orchestrator.refreshPermission(source: .capturePage)

        #expect(catalogService.store.hasScreenCapturePermission == false)
        #expect(sharingService.registerShareableDisplaysCallCount >= 1)
        #expect(sharingService.registeredShareableDisplays.isEmpty)
        #expect(sharingService.stopSharingCallCount == 1)
        #expect(sharingService.activeSharingDisplayIDs.isEmpty)
        #expect(captureService.removedDisplayIDs == [removedDisplayID])
    }

    @Test func topologyChangeCoalescesAndAppliesLatestVisibleDisplays() async {
        let firstDisplayID = CGDirectDisplayID(5001)
        let secondDisplayID = CGDirectDisplayID(5002)
        let firstDisplay = ScreenCatalogOrchestratorMockSCDisplay.make(
            displayID: firstDisplayID,
            width: 1920,
            height: 1080
        )
        let secondDisplay = ScreenCatalogOrchestratorMockSCDisplay.make(
            displayID: secondDisplayID,
            width: 2560,
            height: 1440
        )
        let loadGate = ScreenCatalogOrchestratorLoadGate(
            displaysByCall: [
                [SendableDisplay(firstDisplay)],
                [SendableDisplay(secondDisplay)],
            ]
        )
        let activeDisplayIDs = ScreenCatalogOrchestratorActiveDisplayIDsBox(ids: [firstDisplayID])
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: {
                await loadGate.waitForNextDisplays().map(\.value)
            },
            activeDisplayIDsProvider: {
                activeDisplayIDs.ids
            }
        )

        let sharingService = MockSharingService()
        sharingService.isWebServiceRunning = true
        sharingService.webServiceLifecycleState = .running(.init(requestedPort: 8081, boundPort: 8081))
        let orchestrator = ScreenCatalogOrchestrator(
            catalogService: catalogService,
            capture: CaptureController(
                captureMonitoringService: MockCaptureMonitoringService(),
                catalogService: catalogService
            ),
            sharing: SharingController(
                sharingService: sharingService,
                portPreferences: OrchestratorPortPreferences(),
                catalogService: catalogService
            ),
            virtualDisplay: makeVirtualDisplayController()
        )

        let firstRefresh = Task { await orchestrator.handleTopologyChanged() }
        #expect(await waitForLoaderCall(loadGate, count: 1))

        activeDisplayIDs.ids = [secondDisplayID]
        let secondRefresh = Task { await orchestrator.handleTopologyChanged() }
        await loadGate.release(call: 1)

        #expect(await waitForLoaderCall(loadGate, count: 2))
        await loadGate.release(call: 2)
        await firstRefresh.value
        await secondRefresh.value

        #expect(sharingService.registerShareableDisplaysCallCount >= 2)
        #expect(sharingService.registeredShareableDisplays.map(\.displayID) == [secondDisplayID])
        #expect(catalogService.store.displays?.map(\.displayID) == [secondDisplayID])
    }

    private func makeVirtualDisplayController() -> VirtualDisplayController {
        VirtualDisplayController(
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            appliedBadgeDisplayDuration: .seconds(1),
            stopDependentStreamsBeforeRebuild: { _ in }
        )
    }

    private func makeSession(id: UUID, displayID: CGDirectDisplayID) -> ScreenMonitoringSession {
        ScreenMonitoringSession(
            id: id,
            displayID: displayID,
            displayName: "Display \(displayID)",
            resolutionText: "1920 x 1080",
            isVirtualDisplay: false,
            previewSubscription: DisplayPreviewSubscription(
                displayID: displayID,
                resolutionText: "1920 x 1080",
                session: ScreenCatalogOrchestratorDummySession(),
                cancelClosure: {}
            ),
            capturesCursor: false,
            state: .active
        )
    }

    private func waitForLoaderCall(
        _ gate: ScreenCatalogOrchestratorLoadGate,
        count: Int,
        timeoutNanoseconds: UInt64 = AsyncTestTimeouts.defaultAsyncAssertion,
        pollNanoseconds: UInt64 = 10_000_000
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await gate.currentCallCount() >= count {
                return true
            }
            try? await Task.sleep(for: .nanoseconds(pollNanoseconds))
        }
        return await gate.currentCallCount() >= count
    }

}

private final class ScreenCatalogOrchestratorDummySession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let sessionHub = WebRTCSessionHub()
    nonisolated var shareFrameConsumer: any DisplayShareFrameConsumer { sessionHub }

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func stopSharing() {}

    nonisolated func setDemand(_ demand: DisplayCaptureDemandSnapshot) async throws {
        _ = demand
    }

    nonisolated func stop() async {}
}
