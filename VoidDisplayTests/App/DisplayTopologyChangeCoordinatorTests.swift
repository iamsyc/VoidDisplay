import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing
@testable import VoidDisplay

private final class DisplayTopologyChangeCoordinatorMockSCDisplayBox: NSObject {
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

private enum DisplayTopologyChangeCoordinatorMockSCDisplay {
    static func make(displayID: CGDirectDisplayID, width: Int, height: Int) -> SCDisplay {
        let box = DisplayTopologyChangeCoordinatorMockSCDisplayBox(
            displayID: displayID,
            width: width,
            height: height
        )
        return unsafeBitCast(box, to: SCDisplay.self)
    }
}

private actor DisplayTopologyChangeCoordinatorLoadGate {
    private var displaysByCall: [[SendableDisplay]]
    private var callCount = 0
    private var continuations: [Int: CheckedContinuation<[SendableDisplay], Never>] = [:]

    init(displaysByCall: [[SCDisplay]]) {
        self.displaysByCall = displaysByCall.map { $0.map(SendableDisplay.init) }
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
private final class DisplayTopologyChangeCoordinatorActiveDisplayIDsBox {
    var ids: Set<CGDirectDisplayID>

    init(ids: Set<CGDirectDisplayID>) {
        self.ids = ids
    }
}

@MainActor
struct DisplayTopologyChangeCoordinatorTests {
    private final class TopologyChangePortPreferences: SharingPortPreferencesProtocol {
        var preferredPort: UInt16 = 8081

        func savePreferredPort(_ port: UInt16) {
            preferredPort = port
        }
    }

    @Test func topologyRefreshRegistersVisibleDisplaysAndStopsInvalidSessions() async {
        let removedDisplayID = CGDirectDisplayID(1001)
        let keptDisplayID = CGDirectDisplayID(1002)
        let removedDisplay = DisplayTopologyChangeCoordinatorMockSCDisplay.make(
            displayID: removedDisplayID,
            width: 1920,
            height: 1080
        )
        let keptDisplay = DisplayTopologyChangeCoordinatorMockSCDisplay.make(
            displayID: keptDisplayID,
            width: 2560,
            height: 1440
        )

        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: true,
                requestResult: true
            ),
            loadShareableDisplays: {
                [removedDisplay, keptDisplay]
            },
            activeDisplayIDsProvider: {
                [keptDisplayID]
            }
        )

        let sharingService = MockSharingService()
        sharingService.startResult = .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081))
        sharingService.isWebServiceRunning = true
        sharingService.webServiceLifecycleState = .running(.init(requestedPort: 8081, boundPort: 8081))
        sharingService.activeSharingDisplayIDs = [removedDisplayID, keptDisplayID]
        sharingService.hasAnyActiveSharing = true
        sharingService.shareTargetByDisplayID[removedDisplayID] = .id(1)
        sharingService.shareTargetByDisplayID[keptDisplayID] = .id(2)
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: TopologyChangePortPreferences(),
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
        let virtualDisplay = VirtualDisplayController(
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            appliedBadgeDisplayDuration: .seconds(1),
            stopDependentStreamsBeforeRebuild: { _ in }
        )
        let coordinator = DisplayTopologyChangeCoordinator(
            capture: captureController,
            sharing: sharingController,
            virtualDisplay: virtualDisplay,
            catalogService: catalogService
        )

        coordinator.handleTopologyChange(source: DisplayTopologyChangeCoordinator.Source.sharingView)

        let finished = await waitUntil {
            catalogService.store.displays?.map(\.displayID) == [removedDisplayID, keptDisplayID] &&
                sharingService.registeredShareableDisplays.map(\.displayID) == [keptDisplayID] &&
                sharingService.stopSharingCallCount == 1 &&
                sharingService.activeSharingDisplayIDs == [keptDisplayID] &&
                captureService.removedDisplayIDs == [removedDisplayID]
        }

        #expect(finished)
    }

    @Test func coalescesInFlightTopologyChangesAndAppliesLatestVisibleDisplays() async {
        let firstDisplayID = CGDirectDisplayID(2001)
        let secondDisplayID = CGDirectDisplayID(2002)
        let firstDisplay = DisplayTopologyChangeCoordinatorMockSCDisplay.make(
            displayID: firstDisplayID,
            width: 1920,
            height: 1080
        )
        let secondDisplay = DisplayTopologyChangeCoordinatorMockSCDisplay.make(
            displayID: secondDisplayID,
            width: 2560,
            height: 1440
        )
        let loadGate = DisplayTopologyChangeCoordinatorLoadGate(
            displaysByCall: [[firstDisplay], [secondDisplay]]
        )
        let activeDisplayIDs = DisplayTopologyChangeCoordinatorActiveDisplayIDsBox(ids: [firstDisplayID])
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
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: TopologyChangePortPreferences(),
            catalogService: catalogService
        )
        let captureController = CaptureController(
            captureMonitoringService: MockCaptureMonitoringService(),
            catalogService: catalogService
        )
        let virtualDisplay = VirtualDisplayController(
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            appliedBadgeDisplayDuration: .seconds(1),
            stopDependentStreamsBeforeRebuild: { _ in }
        )
        let coordinator = DisplayTopologyChangeCoordinator(
            capture: captureController,
            sharing: sharingController,
            virtualDisplay: virtualDisplay,
            catalogService: catalogService
        )

        coordinator.handleTopologyChange(source: .sharingView)
        #expect(await waitForCoordinatorLoaderCall(loadGate, count: 1))

        activeDisplayIDs.ids = [secondDisplayID]
        coordinator.handleTopologyChange(source: .captureView)
        await loadGate.release(call: 1)

        #expect(await waitForCoordinatorLoaderCall(loadGate, count: 2))
        await loadGate.release(call: 2)

        let converged = await waitUntil {
            sharingService.registerShareableDisplaysCallCount >= 2 &&
            sharingService.registeredShareableDisplays.map(\.displayID) == [secondDisplayID] &&
            catalogService.store.displays?.map(\.displayID) == [secondDisplayID]
        }
        #expect(converged)
    }

    @Test func permissionDeniedConvergesToEmptyVisibleDisplays() async {
        let removedDisplayID = CGDirectDisplayID(3001)
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(
                preflightResult: false,
                requestResult: false
            ),
            loadShareableDisplays: {
                Issue.record("Display load should not run when permission is denied.")
                return []
            },
            activeDisplayIDsProvider: {
                [removedDisplayID]
            }
        )

        let sharingService = MockSharingService()
        sharingService.isWebServiceRunning = true
        sharingService.webServiceLifecycleState = .running(.init(requestedPort: 8081, boundPort: 8081))
        sharingService.activeSharingDisplayIDs = [removedDisplayID]
        sharingService.hasAnyActiveSharing = true
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: TopologyChangePortPreferences(),
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
        let virtualDisplay = VirtualDisplayController(
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            appliedBadgeDisplayDuration: .seconds(1),
            stopDependentStreamsBeforeRebuild: { _ in }
        )
        let coordinator = DisplayTopologyChangeCoordinator(
            capture: captureController,
            sharing: sharingController,
            virtualDisplay: virtualDisplay,
            catalogService: catalogService
        )

        coordinator.handleTopologyChange(source: .sharingView)

        let converged = await waitUntil {
            catalogService.store.hasScreenCapturePermission == false &&
            sharingService.registerShareableDisplaysCallCount >= 1 &&
            sharingService.registeredShareableDisplays.isEmpty &&
            sharingService.stopSharingCallCount == 1 &&
            sharingService.activeSharingDisplayIDs.isEmpty &&
            captureService.removedDisplayIDs == [removedDisplayID]
        }
        #expect(converged)
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
                session: DisplayTopologyChangeCoordinatorDummySession(),
                cancelClosure: {}
            ),
            capturesCursor: false,
            state: .active
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = AsyncTestTimeouts.defaultAsyncAssertion,
        pollNanoseconds: UInt64 = 10_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .nanoseconds(pollNanoseconds))
        }
        return condition()
    }
}

private func waitForCoordinatorLoaderCall(
    _ gate: DisplayTopologyChangeCoordinatorLoadGate,
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

private final class DisplayTopologyChangeCoordinatorDummySession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let sessionHub = WebRTCSessionHub()

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func stopSharing() {}

    nonisolated func setPreviewShowsCursor(_ showsCursor: Bool) async throws {
        _ = showsCursor
    }

    nonisolated func retainShareCursorOverride() async throws {}

    nonisolated func releaseShareCursorOverride() async throws {}

    nonisolated func stop() async {}
}
