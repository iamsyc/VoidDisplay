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

    @Test func catalogAdapterRetainsScreenCaptureCatalogService() {
        let display = SharedMockSCDisplay.make(displayID: 8301, width: 1440, height: 900)
        var service: ScreenCaptureCatalogService? = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [display] },
            activeDisplayIDsProvider: { [display.displayID] }
        )
        service?.store.hasScreenCapturePermission = true
        service?.store.lastPreflightPermission = true
        service?.store.displays = [display]
        let sut = DisplayRuntimeCatalogAdapter(service: service!)

        service = nil

        let snapshot = sut.makeCatalogSnapshot()
        let visibleDisplays = sut.currentVisibleDisplays()

        #expect(snapshot.hasScreenCapturePermission == true)
        #expect(snapshot.lastPreflightPermission == true)
        #expect(snapshot.loadedDisplays == [
            .init(displayID: display.displayID, pixelWidth: 1440, pixelHeight: 900)
        ])
        #expect(visibleDisplays == [
            .init(displayID: display.displayID, pixelWidth: 1440, pixelHeight: 900)
        ])
    }

    @Test func captureIntentAdapterUnavailableFailsExplicitly() {
        var controller: CaptureController? = CaptureController(
            capturePreviewService: MockCapturePreviewService()
        )
        let sut = DisplayRuntimeCaptureAdapter(controller: controller!)
        controller = nil

        let result = sut.applyCaptureIntent(
            captureIntent(displayID: 8401, revision: 1)
        )

        #expect(result.outcome == .failed)
        #expect(result.revision.rawValue == 1)
        #expect(result.failureCode == DisplayRuntimeCaptureIntentFailureCode.adapterUnavailable)
    }

    @Test func genericCaptureIntentApplyDoesNotResolveDisplayOrStartCapture() {
        let visibleDisplay = SharedMockSCDisplay.make(displayID: 8402, width: 2560, height: 1440)
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: FailingScreenCapturePermissionProvider(),
            loadShareableDisplays: {
                Issue.record("Capture intent adapter must not load shareable displays while applying an intent.")
                return [visibleDisplay]
            },
            activeDisplayIDsProvider: { [visibleDisplay.displayID] }
        )
        catalogService.store.hasScreenCapturePermission = true
        catalogService.store.lastPreflightPermission = true
        catalogService.store.displays = [visibleDisplay]
        let capturePreviewService = MockCapturePreviewService()
        let controller = CaptureController(
            capturePreviewService: capturePreviewService,
            catalogService: catalogService
        )
        let sut = DisplayRuntimeCaptureAdapter(controller: controller)

        let result = sut.applyCaptureIntent(
            captureIntent(displayID: 8403, revision: 2)
        )

        #expect(result.outcome == .applied)
        #expect(result.revision.rawValue == 2)
        #expect(result.failureCode == nil)
        #expect(capturePreviewService.addCallCount == 0)
        #expect(capturePreviewService.removeCallCount == 0)
        #expect(capturePreviewService.removeByDisplayCallCount == 0)
        #expect(capturePreviewService.currentSessions.isEmpty)
    }

    @Test func previewStartAttachesRuntimeLeaseAndAcquiresPreviewThroughAdapter() async throws {
        let display = SharedMockSCDisplay.make(displayID: 8404, width: 2560, height: 1440)
        let harness = previewHarness(display: display)
        let actions = CaptureUIComposition.previewActions(
            capture: harness.controller,
            displayRuntime: harness.runtime
        )

        let outcome = try await actions.startPreview(
            display,
            CapturePreviewDisplayMetadata(
                displayName: "Preview Adapter",
                resolutionText: "2560 × 1440",
                isVirtualDisplay: false
            )
        )

        guard case .started(let sessionID) = outcome else {
            Issue.record("Expected preview start to succeed.")
            return
        }
        let lease = try #require(harness.runtime.currentConsumerLeaseSnapshot().first)
        let effectiveIntent = try #require(harness.runtime.currentEffectiveCaptureIntentSnapshot().first)
        #expect(harness.capturePreviewService.addCallCount == 1)
        #expect(harness.controller.previewSession(for: sessionID)?.displayID == display.displayID)
        #expect(lease.kind == .preview)
        #expect(lease.state == .attached)
        #expect(effectiveIntent.intent.kind == .capture)
        #expect(effectiveIntent.intent.reason == .attach)
        #expect(effectiveIntent.lastApplyResult?.outcome == .applied)
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
                displayName: "Managed Virtual Preview",
                resolutionText: "3008 x 1692",
                isVirtualDisplay: true
            )
        )

        guard case .started(let sessionID) = outcome else {
            Issue.record("Expected managed virtual preview start to succeed.")
            return
        }
        let surfaceIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        let lease = try #require(harness.runtime.currentConsumerLeaseSnapshot().first)
        let effectiveIntent = try #require(harness.runtime.currentEffectiveCaptureIntentSnapshot().first)
        #expect(harness.capturePreviewService.addCallCount == 1)
        #expect(harness.controller.previewSession(for: sessionID)?.displayID == display.displayID)
        #expect(lease.surfaceIdentity == surfaceIdentity)
        #expect(lease.resolvedDisplayID == display.displayID)
        #expect(effectiveIntent.intent.surfaceIdentity == surfaceIdentity)
        #expect(effectiveIntent.intent.resolvedDisplayID == display.displayID)
        #expect(effectiveIntent.lastApplyResult?.outcome == .applied)

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

    @Test func previewStopDetachesRuntimeLeaseAndDrainsPreviewThroughAdapter() async throws {
        let display = SharedMockSCDisplay.make(displayID: 8405, width: 1920, height: 1080)
        let harness = previewHarness(display: display)
        let actions = CaptureUIComposition.previewActions(
            capture: harness.controller,
            displayRuntime: harness.runtime
        )
        let outcome = try await actions.startPreview(
            display,
            CapturePreviewDisplayMetadata(
                displayName: "Preview Adapter",
                resolutionText: "1920 × 1080",
                isVirtualDisplay: false
            )
        )
        guard case .started(let sessionID) = outcome else {
            Issue.record("Expected preview start to succeed.")
            return
        }

        actions.closePreviewSession(sessionID)

        let lease = try #require(harness.runtime.currentConsumerLeaseSnapshot().first)
        let effectiveIntent = try #require(harness.runtime.currentEffectiveCaptureIntentSnapshot().first)
        #expect(lease.state == .released)
        #expect(harness.runtime.currentAggregatedDemandSnapshot().isEmpty)
        #expect(effectiveIntent.intent.kind == .drain)
        #expect(effectiveIntent.intent.reason == .detach)
        #expect(effectiveIntent.lastApplyResult?.outcome == .applied)
        #expect(harness.capturePreviewService.removeByDisplayCallCount == 1)
        #expect(harness.capturePreviewService.removedDisplayIDs == [display.displayID])
        #expect(harness.controller.screenPreviewSessions.isEmpty)
    }

    @Test func previewApplyFailsPermissionUnavailableWithoutStartingSession() async {
        let display = SharedMockSCDisplay.make(displayID: 8406, width: 1920, height: 1080)
        let harness = previewHarness(display: display, hasPermission: false)

        let result = await harness.adapter.applyPreviewCaptureIntent(
            captureIntent(displayID: display.displayID, revision: 3)
        )

        #expect(result.outcome == .failed)
        #expect(result.failureCode == DisplayRuntimeCaptureIntentFailureCode.permissionUnavailable)
        #expect(harness.capturePreviewService.addCallCount == 0)
        #expect(harness.capturePreviewService.removeByDisplayCallCount == 0)
        #expect(harness.controller.screenPreviewSessions.isEmpty)
    }

    @Test func previewApplyFailsDisplayUnavailableWithoutStartingSession() async {
        let display = SharedMockSCDisplay.make(displayID: 8407, width: 1920, height: 1080)
        let harness = previewHarness(display: display)

        let result = await harness.adapter.applyPreviewCaptureIntent(
            captureIntent(displayID: 8408, revision: 4)
        )

        #expect(result.outcome == .failed)
        #expect(result.failureCode == DisplayRuntimeCaptureIntentFailureCode.displayUnavailable)
        #expect(harness.capturePreviewService.addCallCount == 0)
        #expect(harness.capturePreviewService.removeByDisplayCallCount == 0)
        #expect(harness.controller.screenPreviewSessions.isEmpty)
    }

    @Test func lanWebViewStartAttachesUniqueRuntimeLeaseAndStartsSharingThroughIntent() async throws {
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

    @Test func lanViewerAttachDetachUpdatesExistingLeaseWithoutNewCaptureIntent() async throws {
        let display = SharedMockSCDisplay.make(displayID: 8422, width: 2560, height: 1440)
        let target = ShareTarget.id(9422)
        let harness = lanWebViewHarness(display: display, target: target)

        _ = try await harness.sharingAdapter.beginLANWebViewSharing(
            display: display,
            runtime: harness.runtime
        )
        let firstLease = try #require(harness.runtime.currentConsumerLeaseSnapshot().first)
        let firstRevision = try #require(harness.runtime.currentLatestCaptureIntentRevision())

        harness.sharingService.updateSharingStateSnapshot(
            sharingStateSnapshot(target: target, streamingPeers: 3)
        )

        #expect(harness.runtime.currentConsumerLeaseSnapshot().count == 1)
        #expect(harness.runtime.currentConsumerLeaseSnapshot().first?.id == firstLease.id)
        #expect(harness.runtime.currentConsumerLeaseSnapshot().first?.demand.activeViewerCount == 3)
        #expect(harness.runtime.currentAggregatedDemandSnapshot().first?.activeViewerCount == 3)
        #expect(harness.runtime.currentLatestCaptureIntentRevision() == firstRevision)

        harness.sharingService.updateSharingStateSnapshot(
            sharingStateSnapshot(target: target, streamingPeers: 0)
        )

        #expect(harness.runtime.currentConsumerLeaseSnapshot().count == 1)
        #expect(harness.runtime.currentConsumerLeaseSnapshot().first?.id == firstLease.id)
        #expect(harness.runtime.currentConsumerLeaseSnapshot().first?.state == .attached)
        #expect(harness.runtime.currentConsumerLeaseSnapshot().first?.demand.activeViewerCount == 0)
        #expect(harness.runtime.currentLatestCaptureIntentRevision() == firstRevision)
    }

    @Test func lanWebViewStopReleasesRuntimeLeaseAndStopsSharingThroughIntent() async throws {
        let display = SharedMockSCDisplay.make(displayID: 8423, width: 1920, height: 1080)
        let harness = lanWebViewHarness(display: display)

        _ = try await harness.sharingAdapter.beginLANWebViewSharing(
            display: display,
            runtime: harness.runtime
        )

        await harness.sharingAdapter.stopLANWebViewSharing(
            displayID: display.displayID,
            runtime: harness.runtime
        )

        let lease = try #require(harness.runtime.currentConsumerLeaseSnapshot().first)
        let effectiveIntent = try #require(harness.runtime.currentEffectiveCaptureIntentSnapshot().first)
        #expect(lease.kind == .lanWebView)
        #expect(lease.state == .released)
        #expect(harness.runtime.currentAggregatedDemandSnapshot().isEmpty)
        #expect(effectiveIntent.intent.kind == .drain)
        #expect(effectiveIntent.intent.reason == .detach)
        #expect(effectiveIntent.lastApplyResult?.outcome == .applied)
        #expect(harness.sharingService.stopSharingCallCount == 1)
        #expect(harness.sharingService.activeSharingDisplayIDs.isEmpty)
    }

    @Test func lanWebViewStopWithoutRuntimeLeaseDoesNotInvokeDirectSharingStop() async {
        let display = SharedMockSCDisplay.make(displayID: 8429, width: 1920, height: 1080)
        let harness = lanWebViewHarness(display: display)

        await harness.sharingAdapter.stopLANWebViewSharing(
            displayID: display.displayID,
            runtime: harness.runtime
        )

        #expect(harness.sharingService.stopSharingCallCount == 0)
        #expect(harness.runtime.currentEffectiveCaptureIntentSnapshot().isEmpty)
    }

    @Test func lanWebViewApplyFailsPermissionUnavailableWithoutStartingSharing() async throws {
        let display = SharedMockSCDisplay.make(displayID: 8424, width: 1920, height: 1080)
        let harness = lanWebViewHarness(display: display, hasPermission: false)

        let result = await harness.runtime.attachLANWebViewConsumer(
            surfaceIdentity: .physicalDisplay(displayID: display.displayID),
            owner: .init(source: .sharingService, redactedLabel: "lan"),
            demand: DisplayRuntimeConsumerDemand(
                sourcePixelSize: .init(width: display.width, height: display.height),
                sourceFramesPerSecond: 60,
                capturesCursor: false,
                powerProfile: .automatic,
                latencyPreference: .realtime
            )
        )

        let applyResult = try #require(result.applyResult)
        #expect(applyResult.outcome == .failed)
        #expect(applyResult.failureCode == DisplayRuntimeCaptureIntentFailureCode.permissionUnavailable)
        #expect(harness.sharingService.startSharingCallCount == 0)
        #expect(harness.sharingService.activeSharingDisplayIDs.isEmpty)
    }

    @Test func diagnosticsRecorderStandaloneAttachesLeaseAndStartsCaptureThroughAdapter() async throws {
        let display = SharedMockSCDisplay.make(displayID: 8431, width: 2560, height: 1440)
        let harness = previewHarness(display: display)

        let attachResult = await harness.runtime.attachDiagnosticsRecorderConsumer(
            surfaceIdentity: .physicalDisplay(displayID: display.displayID),
            owner: .init(source: .diagnostics, redactedLabel: "recorder"),
            demand: diagnosticsRecorderDemand(display: display)
        )

        let lease = try #require(harness.runtime.currentConsumerLeaseSnapshot().first)
        let effectiveIntent = try #require(harness.runtime.currentEffectiveCaptureIntentSnapshot().first)
        #expect(attachResult.applyResult.outcome == .applied)
        #expect(harness.capturePreviewService.addCallCount == 1)
        #expect(harness.controller.screenPreviewSessions.first?.displayID == display.displayID)
        #expect(lease.kind == .diagnosticsRecorder)
        #expect(lease.state == .attached)
        #expect(effectiveIntent.intent.kind == .capture)
        #expect(effectiveIntent.intent.aggregateDemand?.consumerKinds == [.diagnosticsRecorder])
        #expect(effectiveIntent.lastApplyResult?.outcome == .applied)

        let detachResult = await harness.runtime.detachDiagnosticsRecorderConsumer(
            leaseID: attachResult.lease.id
        )

        #expect(detachResult.applyResult?.outcome == .applied)
        #expect(harness.capturePreviewService.removeByDisplayCallCount == 1)
        #expect(harness.controller.screenPreviewSessions.isEmpty)
        #expect(harness.runtime.currentEffectiveCaptureIntentSnapshot().first?.intent.kind == .drain)
    }

    @Test func diagnosticsRecorderReusesExistingPreviewSessionWithoutDuplicateCapture() async throws {
        let display = SharedMockSCDisplay.make(displayID: 8432, width: 1920, height: 1080)
        let harness = previewHarness(display: display)
        let actions = CaptureUIComposition.previewActions(
            capture: harness.controller,
            displayRuntime: harness.runtime
        )
        let outcome = try await actions.startPreview(
            display,
            CapturePreviewDisplayMetadata(
                displayName: "Preview Adapter",
                resolutionText: "1920 × 1080",
                isVirtualDisplay: false
            )
        )
        guard case .started(let sessionID) = outcome else {
            Issue.record("Expected preview start to succeed.")
            return
        }

        let maybeLeaseToken = await actions.attachDiagnosticsRecorder(sessionID)
        let leaseToken = try #require(maybeLeaseToken)
        await actions.detachDiagnosticsRecorder(leaseToken)

        let leases = harness.runtime.currentConsumerLeaseSnapshot()
        let diagnosticsLease = try #require(leases.first { $0.kind == .diagnosticsRecorder })
        let effectiveIntent = try #require(harness.runtime.currentEffectiveCaptureIntentSnapshot().first)
        #expect(harness.capturePreviewService.addCallCount == 1)
        #expect(harness.capturePreviewService.removeByDisplayCallCount == 0)
        #expect(leases.filter { $0.kind == .preview }.first?.state == .attached)
        #expect(diagnosticsLease.state == .released)
        #expect(effectiveIntent.intent.kind == .capture)
        #expect(effectiveIntent.intent.aggregateDemand?.consumerKinds == [.preview])
        #expect(effectiveIntent.lastApplyResult?.outcome == .applied)
    }

    @Test func diagnosticsRecorderReusesActiveLANWebViewPathWithoutStartingPreview() async throws {
        let display = SharedMockSCDisplay.make(displayID: 8433, width: 3840, height: 2160)
        let harness = lanWebViewHarness(display: display)

        _ = try await harness.sharingAdapter.beginLANWebViewSharing(
            display: display,
            runtime: harness.runtime
        )
        let attachResult = await harness.runtime.attachDiagnosticsRecorderConsumer(
            surfaceIdentity: .physicalDisplay(displayID: display.displayID),
            owner: .init(source: .diagnostics, redactedLabel: "recorder"),
            demand: diagnosticsRecorderDemand(display: display)
        )

        let aggregate = try #require(harness.runtime.currentAggregatedDemandSnapshot().first)
        #expect(attachResult.applyResult.outcome == .applied)
        #expect(harness.sharingService.startSharingCallCount == 1)
        #expect(harness.captureController.screenPreviewSessions.isEmpty)
        #expect(aggregate.consumerKinds == [.diagnosticsRecorder, .lanWebView])
        #expect(aggregate.effectivePixelSize == .init(width: 3840, height: 2160))
        #expect(aggregate.effectiveFramesPerSecond == 60)
        #expect(aggregate.latencyPreference == .realtime)
    }

    @Test func sharingAdapterResolvesSCDisplayAndVirtualSerialInAppLayer() {
        let skippedDisplay = SharedMockSCDisplay.make(displayID: 8201, width: 1920, height: 1080)
        let registeredDisplay = SharedMockSCDisplay.make(displayID: 8202, width: 3840, height: 2160)
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [skippedDisplay, registeredDisplay] },
            activeDisplayIDsProvider: { [registeredDisplay.displayID] }
        )
        catalogService.store.displays = [skippedDisplay, registeredDisplay]
        let sharingService = MockSharingService()
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: AdapterTestPortPreferences(),
            catalogService: catalogService
        )
        let sut = DisplayRuntimeSharingAdapter(controller: sharingController)

        sut.registerShareableDisplays([
            .init(displayID: registeredDisplay.displayID, virtualSerialNumber: 9202)
        ])

        #expect(sharingService.registerShareableDisplaysCallCount == 1)
        #expect(sharingService.registeredShareableDisplays.map(\.displayID) == [registeredDisplay.displayID])
        #expect(sharingService.registeredVirtualSerialsByDisplayID[registeredDisplay.displayID] == 9202)
        #expect(sharingService.registeredVirtualSerialsByDisplayID[skippedDisplay.displayID] == nil)
    }

    @Test func sharingAdapterRestoreResolvesCatalogDisplayAndStartsSharing() async {
        let display = SharedMockSCDisplay.make(displayID: 8211, width: 2560, height: 1440)
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [display] },
            activeDisplayIDsProvider: { [display.displayID] }
        )
        catalogService.store.displays = [display]
        let sharingService = MockSharingService()
        sharingService.isWebServiceRunning = true
        sharingService.shareIDByDisplayID[display.displayID] = 9211
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: AdapterTestPortPreferences(),
            catalogService: catalogService
        )
        let sut = DisplayRuntimeSharingAdapter(controller: sharingController)

        let result = await sut.restoreSharing(displayID: display.displayID)

        #expect(result == .restored)
        #expect(sharingService.startSharingCallCount == 1)
        #expect(sharingService.startedSharingDisplayIDs == [display.displayID])
    }

    @Test func sharingAdapterRestoreFailsWhenCatalogDisplayIsMissing() async {
        let display = SharedMockSCDisplay.make(displayID: 8212, width: 2560, height: 1440)
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [display] },
            activeDisplayIDsProvider: { [display.displayID] }
        )
        catalogService.store.displays = []
        let sharingService = MockSharingService()
        sharingService.isWebServiceRunning = true
        sharingService.shareIDByDisplayID[display.displayID] = 9212
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: AdapterTestPortPreferences(),
            catalogService: catalogService
        )
        let sut = DisplayRuntimeSharingAdapter(controller: sharingController)

        let result = await sut.restoreSharing(displayID: display.displayID)

        #expect(result.status == .failed)
        #expect(result.failureReason == "display_not_found")
        #expect(sharingService.startSharingCallCount == 0)
    }

    @Test func sharingAdapterRestoreSkipsWhenWebServiceIsStopped() async {
        let display = SharedMockSCDisplay.make(displayID: 8216, width: 2560, height: 1440)
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [display] },
            activeDisplayIDsProvider: { [display.displayID] }
        )
        catalogService.store.displays = [display]
        let sharingService = MockSharingService()
        sharingService.isWebServiceRunning = false
        sharingService.shareIDByDisplayID[display.displayID] = 9216
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: AdapterTestPortPreferences(),
            catalogService: catalogService
        )
        let sut = DisplayRuntimeSharingAdapter(controller: sharingController)

        let result = await sut.restoreSharing(displayID: display.displayID)

        #expect(result.status == .skipped)
        #expect(result.failureReason == "web_service_not_running")
        #expect(sharingService.startSharingCallCount == 0)
    }

    @Test func sharingAdapterRestoreFailsWhenShareableRegistrationIsMissing() async {
        let display = SharedMockSCDisplay.make(displayID: 8213, width: 2560, height: 1440)
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [display] },
            activeDisplayIDsProvider: { [display.displayID] }
        )
        catalogService.store.displays = [display]
        let sharingService = MockSharingService()
        sharingService.isWebServiceRunning = true
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: AdapterTestPortPreferences(),
            catalogService: catalogService
        )
        let sut = DisplayRuntimeSharingAdapter(controller: sharingController)

        let result = await sut.restoreSharing(displayID: display.displayID)

        #expect(result.status == .failed)
        #expect(result.failureReason == "shareable_display_not_registered")
        #expect(sharingService.startSharingCallCount == 0)
    }

    @Test func sharingAdapterRestoreMapsBeginSharingInvalidationAndFailure() async {
        struct ControlledError: Error {}

        let invalidatedDisplay = SharedMockSCDisplay.make(displayID: 8214, width: 2560, height: 1440)
        let failedDisplay = SharedMockSCDisplay.make(displayID: 8215, width: 2560, height: 1440)
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [invalidatedDisplay, failedDisplay] },
            activeDisplayIDsProvider: { [invalidatedDisplay.displayID, failedDisplay.displayID] }
        )
        catalogService.store.displays = [invalidatedDisplay, failedDisplay]
        let sharingService = MockSharingService()
        sharingService.isWebServiceRunning = true
        sharingService.shareIDByDisplayID[invalidatedDisplay.displayID] = 9214
        sharingService.shareIDByDisplayID[failedDisplay.displayID] = 9215
        sharingService.startSharingHandler = { display in
            if display.displayID == invalidatedDisplay.displayID {
                return .invalidated
            }
            throw ControlledError()
        }
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: AdapterTestPortPreferences(),
            catalogService: catalogService
        )
        let sut = DisplayRuntimeSharingAdapter(controller: sharingController)

        let invalidatedResult = await sut.restoreSharing(displayID: invalidatedDisplay.displayID)
        let failedResult = await sut.restoreSharing(displayID: failedDisplay.displayID)

        #expect(invalidatedResult.status == .invalidated)
        #expect(invalidatedResult.failureReason == "sharing_start_invalidated")
        #expect(failedResult.status == .failed)
        #expect(sharingService.startedSharingDisplayIDs == [invalidatedDisplay.displayID, failedDisplay.displayID])
    }

    @Test func virtualDisplayAdapterRebuildCallsLowerFacade() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Adapter",
            serialNum: 9301,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        facade.currentRunningConfigIds = [config.id]
        facade.runtimeDisplayIDByConfigId[config.id] = 8302
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller, commandFacade: facade)

        let result = try await sut.rebuildVirtualDisplay(configID: config.id)

        #expect(facade.rebuildVirtualDisplayCallCount == 1)
        #expect(facade.rebuildVirtualDisplayConfigIds == [config.id])
        #expect(result.configID == config.id)
        #expect(result.preDisplayID == 8302)
        #expect(result.postDisplayID == 8302)
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

    @Test func virtualDisplayAdapterEnableUsesLowerFacade() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Enable Adapter",
            serialNum: 9302,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: false
        )
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        facade.runtimeDisplayIDByConfigId[config.id] = 8303
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller, commandFacade: facade)

        _ = try await sut.setVirtualDisplayDesiredEnabled(request: .init(configID: config.id, enabled: true))
        let result = try await sut.enableVirtualDisplay(
            request: .init(configID: config.id, targetPreDisplayID: nil)
        )

        #expect(facade.setDesiredEnabledRequests.map(\.0) == [config.id])
        #expect(facade.enableRuntimeDisplayConfigIDs == [config.id])
        #expect(facade.enableRuntimeDisplayCallCount == 1)
        #expect(result.desiredEnabled == true)
        #expect(result.preDisplayID == 8303)
        #expect(result.postDisplayID == 8303)
    }

    @Test func virtualDisplayAdapterDisableUsesLowerFacade() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Disable Adapter",
            serialNum: 9303,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        facade.currentRunningConfigIds = [config.id]
        facade.runtimeDisplayIDByConfigId[config.id] = 8304
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller, commandFacade: facade)

        _ = try await sut.setVirtualDisplayDesiredEnabled(request: .init(configID: config.id, enabled: false))
        let result = try await sut.disableVirtualDisplay(
            request: .init(configID: config.id, targetPreDisplayID: 8304)
        )

        #expect(facade.setDesiredEnabledRequests.map(\.0) == [config.id])
        #expect(facade.disableRuntimeDisplayByConfigIDs == [config.id])
        #expect(facade.disableRuntimeDisplayByConfigCallCount == 1)
        #expect(result.desiredEnabled == false)
        #expect(result.preDisplayID == 8304)
        #expect(result.postDisplayID == nil)
    }

    @Test func virtualDisplayAdapterSaveConfigForRebuildUsesLowerFacadeAndReturnsPreviousConfig() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Old Adapter Name",
            serialNum: 9304,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        var edited = config
        edited.displayName = "New Adapter Name"
        edited.serialNum = 9305
        edited.physicalWidth = 620
        edited.physicalHeight = 360
        edited.modes = [
            .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false),
            .init(width: 2560, height: 1440, refreshRate: 75, enableHiDPI: true)
        ]
        edited.desiredEnabled = false
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller, commandFacade: facade)

        let result = try await sut.saveConfigForRebuild(
            request: .init(
                editedConfig: editDTO(config: edited),
                expectedConfigFingerprint: config.editRebuildFingerprint,
                source: .editSaveAndRebuild
            )
        )

        #expect(facade.configForEditRebuildIDs == [config.id])
        #expect(facade.saveConfigForRebuildCallCount == 1)
        #expect(facade.savedConfigForRebuildIDs == [config.id])
        #expect(facade.updateConfigCallCount == 0)
        #expect(facade.currentDisplayConfigs.first?.displayName == "New Adapter Name")
        #expect(facade.currentDisplayConfigs.first?.serialNum == 9305)
        #expect(facade.currentDisplayConfigs.first?.physicalWidth == 620)
        #expect(facade.currentDisplayConfigs.first?.physicalHeight == 360)
        #expect(facade.currentDisplayConfigs.first?.modes == edited.modes)
        #expect(facade.currentDisplayConfigs.first?.desiredEnabled == false)
        #expect(result.persistenceOutcome == .saved)
        #expect(result.previousConfigForCompensation.displayName == "Old Adapter Name")
        #expect(result.previousConfigForCompensation.serialNumber == 9304)
        #expect(result.previousConfigForCompensation.physicalWidthMillimeters == 600)
        #expect(result.previousConfigForCompensation.physicalHeightMillimeters == 340)
        #expect(result.previousConfigForCompensation.modes == [
            .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
        ])
        #expect(result.savedConfigEvidence.serialNumber == 9305)
        #expect(result.savedConfigEvidence.desiredEnabled == false)
        #expect(result.savedConfigEvidence.physicalWidthMillimeters == 620)
        #expect(result.savedConfigEvidence.physicalHeightMillimeters == 360)
        #expect(result.savedConfigEvidence.modeCount == 2)
        #expect(result.savedConfigEvidence.maximumPixelWidth == 5120)
        #expect(result.savedConfigEvidence.maximumPixelHeight == 2880)
        #expect(controller.persistenceAlert == nil)
    }

    @Test func virtualDisplayAdapterSaveConfigForRebuildDetectsStaleFingerprintBeforeSaving() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Stale Adapter Name",
            serialNum: 9306,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller, commandFacade: facade)

        await #expect(throws: DisplayRuntimeVirtualDisplayEditRebuildSaveCommandError.self) {
            _ = try await sut.saveConfigForRebuild(
                request: .init(
                    editedConfig: editDTO(config: config),
                    expectedConfigFingerprint: "stale",
                    source: .editSaveAndRebuild
                )
            )
        }

        #expect(facade.configForEditRebuildIDs == [config.id])
        #expect(facade.saveConfigForRebuildCallCount == 0)
        #expect(controller.persistenceAlert == nil)
    }

    @Test func virtualDisplayAdapterLowerFacadeSaveFailureDoesNotSetPersistenceAlert() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Save Failure",
            serialNum: 9307,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        facade.saveConfigForRebuildError = NSError(domain: "LowerFacadeSave", code: 7)
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller, commandFacade: facade)

        await #expect(throws: (any Error).self) {
            _ = try await sut.saveConfigForRebuild(
                request: .init(
                    editedConfig: editDTO(config: config),
                    expectedConfigFingerprint: config.editRebuildFingerprint,
                    source: .editSaveAndRebuild
                )
            )
        }

        #expect(facade.saveConfigForRebuildCallCount == 1)
        #expect(controller.persistenceAlert == nil)
    }

    @Test func virtualDisplayAdapterRestoreConfigAfterFailedEditUsesLowerFacade() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Edited",
            serialNum: 9308,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        var previous = config
        previous.displayName = "Previous"
        previous.serialNum = 9309
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller, commandFacade: facade)

        let result = try await sut.restoreConfigAfterFailedEdit(
            request: .init(
                transactionID: DisplayRuntimeTransactionID(),
                previousConfigForCompensation: editDTO(config: previous)
            )
        )

        #expect(result.persistenceOutcome == .rolledBack)
        #expect(facade.restoreConfigAfterFailedEditCallCount == 1)
        #expect(facade.restoredConfigAfterFailedEditIDs == [config.id])
        #expect(facade.updateConfigCallCount == 0)
        #expect(facade.currentDisplayConfigs.first?.displayName == "Previous")
        #expect(controller.persistenceAlert == nil)
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
    hasPermission: Bool = true,
    virtualDisplaySnapshot: DisplayRuntimeVirtualDisplaySnapshot? = nil
) -> (
    catalogService: ScreenCaptureCatalogService,
    capturePreviewService: MockCapturePreviewService,
    controller: CaptureController,
    adapter: DisplayRuntimeCaptureAdapter,
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
    catalogService.store.hasScreenCapturePermission = hasPermission
    catalogService.store.lastPreflightPermission = hasPermission
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
        adapter: adapter,
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
    display: SCDisplay,
    target: ShareTarget? = nil,
    hasPermission: Bool = true
) -> (
    catalogService: ScreenCaptureCatalogService,
    sharingService: MockSharingService,
    sharingController: SharingController,
    sharingAdapter: DisplayRuntimeSharingAdapter,
    captureController: CaptureController,
    captureAdapter: DisplayRuntimeCaptureAdapter,
    runtime: DisplayRuntime
) {
    let resolvedTarget = target ?? .id(9400 + UInt32(display.displayID % 100))
    let catalogService = ScreenCaptureCatalogService(
        permissionProvider: FailingScreenCapturePermissionProvider(),
        loadShareableDisplays: {
            Issue.record("LAN Web View runtime tests must not load real shareable displays.")
            return [display]
        },
        activeDisplayIDsProvider: { [display.displayID] }
    )
    catalogService.store.hasScreenCapturePermission = hasPermission
    catalogService.store.lastPreflightPermission = hasPermission
    catalogService.store.displays = [display]

    let sharingService = MockSharingService()
    sharingService.isWebServiceRunning = true
    sharingService.webServiceLifecycleState = .running(
        WebServiceBinding(requestedPort: 8081, boundPort: 8081)
    )
    if case .id(let shareID) = resolvedTarget {
        sharingService.shareIDByDisplayID[display.displayID] = shareID
    }
    sharingService.shareTargetByDisplayID[display.displayID] = resolvedTarget

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
        sharingAdapter: sharingAdapter,
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

private func sharingStateSnapshot(
    target: ShareTarget,
    streamingPeers: Int
) -> SharingStateSnapshot {
    SharingStateSnapshot(
        signalingConnections: streamingPeers,
        streamingPeers: streamingPeers,
        signalingConnectionsByTarget: [target: streamingPeers],
        streamingPeersByTarget: [target: streamingPeers],
        clientsByTarget: [:],
        lastUpdatedAt: Date()
    )
}

private func diagnosticsRecorderDemand(display: SCDisplay) -> DisplayRuntimeConsumerDemand {
    DisplayRuntimeConsumerDemand(
        sourcePixelSize: .init(width: display.width, height: display.height),
        preferredPixelSize: .init(width: min(display.width, 1280), height: min(display.height, 720)),
        sourceFramesPerSecond: 60,
        preferredFramesPerSecond: 15,
        capturesCursor: false,
        powerProfile: .powerEfficient,
        latencyPreference: .recording
    )
}

private struct FailingScreenCapturePermissionProvider: ScreenCapturePermissionProvider {
    nonisolated func preflight() -> Bool {
        Issue.record("Capture intent adapter must not preflight screen capture permission while applying an intent.")
        return false
    }

    nonisolated func request() -> Bool {
        Issue.record("Capture intent adapter must not request screen capture permission while applying an intent.")
        return false
    }
}

private func captureIntent(
    displayID: DisplayRuntimeDisplayID?,
    revision: UInt64,
    kind: DisplayRuntimeCaptureIntentKind = .capture,
    reason: DisplayRuntimeCaptureIntentReason = .attach
) -> DisplayRuntimeCaptureIntent {
    DisplayRuntimeCaptureIntent(
        surfaceIdentity: .physicalDisplay(displayID: displayID ?? 0),
        surfaceEpoch: .initial,
        resolvedDisplayID: displayID,
        aggregateDemand: nil,
        kind: kind,
        reason: reason,
        revision: .init(rawValue: revision)
    )
}

private func editDTO(config: VirtualDisplayConfig) -> DisplayRuntimeVirtualDisplayConfigEditDTO {
    DisplayRuntimeVirtualDisplayConfigEditDTO(adapterConfig: config)
}
