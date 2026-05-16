@testable import VoidDisplayApp
@testable import VoidDisplayCapture
@testable import VoidDisplayRuntime
@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayVirtualDisplayTestingSupport
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeAdapterTests {
    @Test func catalogAdapterReturnsOnlyCurrentVisibleDisplayDTOs() {
        let hiddenDisplay = SharedMockSCDisplay.make(displayID: 8101, width: 1920, height: 1080)
        let visibleDisplay = SharedMockSCDisplay.make(displayID: 8102, width: 2560, height: 1440)
        let service = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [hiddenDisplay, visibleDisplay] },
            activeDisplayIDsProvider: { [visibleDisplay.displayID] }
        )
        service.store.displays = [hiddenDisplay, visibleDisplay]
        let sut = DisplayRuntimeCatalogAdapter(service: service)

        let displays = sut.currentVisibleDisplays()

        #expect(displays == [
            .init(displayID: visibleDisplay.displayID, pixelWidth: 2560, pixelHeight: 1440)
        ])
    }

    @Test func captureIntentAdapterUnavailableFailsExplicitly() {
        var controller: CaptureController? = CaptureController(
            capturePreviewService: MockCapturePreviewService()
        )
        let sut = DisplayRuntimeCaptureAdapter(controller: controller!)
        controller = nil

        let result = sut.applyCaptureIntent(
            DisplayRuntimeCaptureIntent(
                surfaceIdentity: .physicalDisplay(displayID: 8401),
                surfaceEpoch: .initial,
                resolvedDisplayID: 8401,
                aggregateDemand: nil,
                kind: .capture,
                reason: .attach,
                revision: .init(rawValue: 1)
            )
        )

        #expect(result.outcome == .failed)
        #expect(result.revision.rawValue == 1)
        #expect(result.failureCode == DisplayRuntimeCaptureIntentFailureCode.adapterUnavailable)
    }

    @Test func previewStartAndStopResolveManagedVirtualDisplaySurface() async throws {
        let configID = UUID(uuidString: "13131313-1313-1313-1313-131313131313")!
        let display = SharedMockSCDisplay.make(displayID: 8416, width: 3008, height: 1692)
        let harness = previewHarness(
            display: display,
            virtualDisplaySnapshot: managedVirtualDisplaySnapshot(
                configID: configID,
                displayID: display.displayID
            )
        )
        let actions = CaptureUIComposition.previewActions(
            capture: harness.controller,
            displayRuntime: harness.runtime
        )

        let outcome = try await actions.startPreview(
            display,
            CapturePreviewDisplayMetadata(
                displayName: "Preview Adapter",
                resolutionText: "3008 x 1692",
                isVirtualDisplay: true
            )
        )

        guard case .started(let sessionID) = outcome else {
            Issue.record("Expected managed virtual preview start to succeed.")
            return
        }
        let surfaceIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        let attachedLease = try #require(harness.runtime.currentConsumerLeaseSnapshot().first)
        let captureIntent = try #require(harness.runtime.currentEffectiveCaptureIntentSnapshot().first)
        #expect(harness.capturePreviewService.addCallCount == 1)
        #expect(harness.controller.previewSession(for: sessionID)?.displayID == display.displayID)
        #expect(attachedLease.surfaceIdentity == surfaceIdentity)
        #expect(attachedLease.resolvedDisplayID == display.displayID)
        #expect(captureIntent.intent.surfaceIdentity == surfaceIdentity)
        #expect(captureIntent.intent.resolvedDisplayID == display.displayID)
        #expect(captureIntent.lastApplyResult?.outcome == .applied)

        actions.closePreviewSession(sessionID)

        let releasedLease = try #require(harness.runtime.currentConsumerLeaseSnapshot().first)
        let drainIntent = try #require(harness.runtime.currentEffectiveCaptureIntentSnapshot().first)
        #expect(releasedLease.surfaceIdentity == surfaceIdentity)
        #expect(releasedLease.state == .released)
        #expect(harness.runtime.currentAggregatedDemandSnapshot().isEmpty)
        #expect(drainIntent.intent.surfaceIdentity == surfaceIdentity)
        #expect(drainIntent.intent.kind == .drain)
        #expect(drainIntent.lastApplyResult?.outcome == .applied)
        #expect(harness.capturePreviewService.removeByDisplayCallCount == 1)
        #expect(harness.controller.screenPreviewSessions.isEmpty)
    }

    @Test func lanWebViewStartAttachesRuntimeLeaseAndStartsSharingThroughIntent() async throws {
        let display = SharedMockSCDisplay.make(displayID: 8421, width: 3840, height: 2160)
        let harness = lanWebViewHarness(display: display)
        let dependencies = SharingUIComposition.dependencies(
            sharing: harness.sharingController,
            virtualDisplay: VirtualDisplayController(
                virtualDisplayFacade: MockVirtualDisplayFacade(),
                appliedBadgeDisplayDuration: .nanoseconds(1)
            ),
            displayRuntime: harness.runtime
        )

        let outcome = try await dependencies.sharingActions.beginSharing(display)

        guard case .started = outcome else {
            Issue.record("Expected LAN Web View sharing start to succeed.")
            return
        }
        let lease = try #require(harness.runtime.currentConsumerLeaseSnapshot().first)
        let effectiveIntent = try #require(harness.runtime.currentEffectiveCaptureIntentSnapshot().first)
        #expect(harness.sharingService.startSharingCallCount == 1)
        #expect(harness.sharingService.startedSharingDisplayIDs == [display.displayID])
        #expect(lease.kind == .lanWebView)
        #expect(lease.state == .attached)
        #expect(lease.demand.sourcePixelSize == .init(width: 3840, height: 2160))
        #expect(lease.demand.activeViewerCount == 0)
        #expect(effectiveIntent.intent.kind == .capture)
        #expect(effectiveIntent.intent.reason == .attach)
        #expect(effectiveIntent.intent.aggregateDemand?.consumerKinds == [.lanWebView])
        #expect(effectiveIntent.lastApplyResult?.outcome == .applied)
    }

    @Test func virtualDisplayAdapterSnapshotMapsConfigAndManagedDisplayDTOFields() throws {
        let config = VirtualDisplayConfig(
            displayName: "Snapshot Mapping",
            serialNum: 9300,
            physicalWidth: 610,
            physicalHeight: 350,
            modes: [
                .init(width: 2560, height: 1440, refreshRate: 75, enableHiDPI: true),
                .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
            ],
            desiredEnabled: true
        )
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        facade.currentRunningConfigIds = [config.id]
        facade.runtimeDisplayIDByConfigId[config.id] = 8300
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller, commandFacade: facade)

        let snapshot = sut.makeVirtualDisplaySnapshot()
        let dto = try #require(snapshot.configs.first)

        #expect(snapshot.runningConfigIDs == [config.id])
        #expect(snapshot.managedDisplays == [
            DisplayRuntimeManagedVirtualDisplay(
                configID: config.id,
                serialNumber: 9300,
                displayID: 8300,
                isLiveRuntime: true
            )
        ])
        #expect(dto.id == config.id)
        #expect(dto.serialNumber == 9300)
        #expect(dto.desiredEnabled)
        #expect(dto.physicalWidthMillimeters == 610)
        #expect(dto.physicalHeightMillimeters == 350)
        #expect(dto.modes == [
            DisplayRuntimeVirtualDisplayMode(
                width: 1920,
                height: 1080,
                refreshRate: 60,
                enableHiDPI: false
            ),
            DisplayRuntimeVirtualDisplayMode(
                width: 2560,
                height: 1440,
                refreshRate: 75,
                enableHiDPI: true
            )
        ])
    }
}

private final class AdapterTestPortPreferences: SharingPortPreferencesProtocol {
    var preferredPort: UInt16 = 8081

    func savePreferredPort(_ port: UInt16) {
        preferredPort = port
    }
}

private final class AdapterPreviewDummySession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let shareFrameConsumer: any DisplayShareFrameConsumer = TestDisplayShareFrameConsumer()

    nonisolated func attachPreviewSink(_: any DisplayPreviewSink) {}

    nonisolated func detachPreviewSink(_: any DisplayPreviewSink) {}

    nonisolated func stopSharing() {}

    nonisolated func stop() async {}
}

@MainActor
private func previewHarness(
    display: SCDisplay,
    virtualDisplaySnapshot: DisplayRuntimeVirtualDisplaySnapshot? = nil
) -> (
    catalogService: ScreenCaptureCatalogService,
    capturePreviewService: MockCapturePreviewService,
    controller: CaptureController,
    runtime: DisplayRuntime
) {
    let catalogService = ScreenCaptureCatalogService(
        permissionProvider: FailingScreenCapturePermissionProvider(),
        loadShareableDisplays: {
            Issue.record("Preview wiring tests must not load real shareable displays.")
            return [display]
        },
        activeDisplayIDsProvider: { [display.displayID] }
    )
    catalogService.store.hasScreenCapturePermission = true
    catalogService.store.lastPreflightPermission = true
    catalogService.store.displays = [display]

    let capturePreviewService = MockCapturePreviewService()
    let lifecycleService = CapturePreviewLifecycleService(
        capturePreviewService: capturePreviewService,
        acquirePreview: { captureDisplay, _ in
            .started(
                DisplayPreviewSubscription(
                    displayID: captureDisplay.displayID,
                    resolutionText: "\(captureDisplay.width) × \(captureDisplay.height)",
                    session: AdapterPreviewDummySession(),
                    cancelClosure: {}
                )
            )
        }
    )
    let controller = CaptureController(
        capturePreviewService: capturePreviewService,
        capturePreviewLifecycleService: lifecycleService,
        catalogService: catalogService
    )
    let adapter = DisplayRuntimeCaptureAdapter(controller: controller)
    let runtime = DisplayRuntime(
        catalogProvider: DisplayRuntimeCatalogAdapter(service: catalogService),
        captureProvider: adapter,
        virtualDisplayProvider: virtualDisplaySnapshot.map(AdapterTestVirtualDisplayProvider.init),
        captureIntentCommander: adapter
    )
    return (
        catalogService: catalogService,
        capturePreviewService: capturePreviewService,
        controller: controller,
        runtime: runtime
    )
}

private final class AdapterTestVirtualDisplayProvider: DisplayRuntimeVirtualDisplayProviding {
    private let snapshot: DisplayRuntimeVirtualDisplaySnapshot

    init(snapshot: DisplayRuntimeVirtualDisplaySnapshot) {
        self.snapshot = snapshot
    }

    func makeVirtualDisplaySnapshot() -> DisplayRuntimeVirtualDisplaySnapshot {
        snapshot
    }
}

@MainActor
private func lanWebViewHarness(
    display: SCDisplay
) -> (
    catalogService: ScreenCaptureCatalogService,
    sharingService: MockSharingService,
    sharingController: SharingController,
    captureController: CaptureController,
    captureAdapter: DisplayRuntimeCaptureAdapter,
    runtime: DisplayRuntime
) {
    let catalogService = ScreenCaptureCatalogService(
        permissionProvider: FailingScreenCapturePermissionProvider(),
        loadShareableDisplays: {
            Issue.record("LAN Web View runtime tests must not load real shareable displays.")
            return [display]
        },
        activeDisplayIDsProvider: { [display.displayID] }
    )
    catalogService.store.hasScreenCapturePermission = true
    catalogService.store.lastPreflightPermission = true
    catalogService.store.displays = [display]

    let target = ShareTarget.id(9400 + UInt32(display.displayID % 100))
    let sharingService = MockSharingService()
    sharingService.isWebServiceRunning = true
    sharingService.webServiceLifecycleState = .running(
        WebServiceBinding(requestedPort: 8081, boundPort: 8081)
    )
    if case .id(let shareID) = target {
        sharingService.shareIDByDisplayID[display.displayID] = shareID
    }
    sharingService.shareTargetByDisplayID[display.displayID] = target

    let sharingController = SharingController(
        sharingService: sharingService,
        portPreferences: AdapterTestPortPreferences(),
        catalogService: catalogService
    )
    let captureController = CaptureController(
        capturePreviewService: MockCapturePreviewService(),
        catalogService: catalogService
    )
    let sharingAdapter = DisplayRuntimeSharingAdapter(controller: sharingController)
    let captureAdapter = DisplayRuntimeCaptureAdapter(
        controller: captureController,
        sharingController: sharingController
    )
    let runtime = DisplayRuntime(
        catalogProvider: DisplayRuntimeCatalogAdapter(service: catalogService),
        captureProvider: captureAdapter,
        sharingProvider: sharingAdapter,
        sharingCommander: sharingAdapter,
        captureIntentCommander: captureAdapter
    )
    sharingAdapter.configureLANWebViewDemandSync(runtime: runtime)
    return (
        catalogService: catalogService,
        sharingService: sharingService,
        sharingController: sharingController,
        captureController: captureController,
        captureAdapter: captureAdapter,
        runtime: runtime
    )
}

private func managedVirtualDisplaySnapshot(
    configID: UUID,
    displayID: DisplayRuntimeDisplayID
) -> DisplayRuntimeVirtualDisplaySnapshot {
    .init(
        rebuildRequestCount: 0,
        rebuildingConfigIDs: [],
        runningConfigIDs: [configID],
        recentlyAppliedConfigIDs: [],
        rebuildFailureConfigIDs: [],
        configStoreHasLoadFailure: false,
        configStoreHasDiagnostics: false,
        managedDisplays: [
            .init(configID: configID, serialNumber: 9416, displayID: displayID, isLiveRuntime: true)
        ],
        configs: [
            .init(
                id: configID,
                serialNumber: 9416,
                desiredEnabled: true,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                modes: [.init(width: 1504, height: 846, refreshRate: 60, enableHiDPI: true)]
            )
        ],
        restoreFailureConfigIDs: []
    )
}

private struct FailingScreenCapturePermissionProvider: ScreenCapturePermissionProvider {
    nonisolated func preflight() -> Bool {
        Issue.record("Adapter tests must not preflight screen capture permission.")
        return false
    }

    nonisolated func request() -> Bool {
        Issue.record("Adapter tests must not request screen capture permission.")
        return false
    }
}
