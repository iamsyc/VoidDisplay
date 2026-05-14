@testable import VoidDisplayApp
@testable import VoidDisplayCapture
@testable import VoidDisplayRuntime
@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
@testable import VoidDisplayVirtualDisplay
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
            captureMonitoringService: MockCaptureMonitoringService()
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

    @Test func captureIntentAdapterFailsWhenDisplayIDCannotResolveWithoutStartingCapture() {
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
        let captureMonitoringService = MockCaptureMonitoringService()
        let controller = CaptureController(
            captureMonitoringService: captureMonitoringService,
            catalogService: catalogService
        )
        let sut = DisplayRuntimeCaptureAdapter(controller: controller)

        let result = sut.applyCaptureIntent(
            captureIntent(displayID: 8403, revision: 2)
        )

        #expect(result.outcome == .failed)
        #expect(result.revision.rawValue == 2)
        #expect(result.failureCode == DisplayRuntimeCaptureIntentFailureCode.displayUnavailable)
        #expect(captureMonitoringService.addCallCount == 0)
        #expect(captureMonitoringService.removeCallCount == 0)
        #expect(captureMonitoringService.removeByDisplayCallCount == 0)
        #expect(captureMonitoringService.currentSessions.isEmpty)
    }

    @Test func monitorStartAttachesRuntimeLeaseAndAcquiresPreviewThroughAdapter() async throws {
        let display = SharedMockSCDisplay.make(displayID: 8404, width: 2560, height: 1440)
        let harness = monitorHarness(display: display)
        let actions = CaptureUIComposition.monitoringActions(
            capture: harness.controller,
            displayRuntime: harness.runtime
        )

        let outcome = try await actions.startMonitoring(
            display,
            CaptureMonitoringDisplayMetadata(
                displayName: "Monitor Adapter",
                resolutionText: "2560 × 1440",
                isVirtualDisplay: false
            )
        )

        guard case .started(let sessionID) = outcome else {
            Issue.record("Expected monitor start to succeed.")
            return
        }
        let lease = try #require(harness.runtime.currentConsumerLeaseSnapshot().first)
        let effectiveIntent = try #require(harness.runtime.currentEffectiveCaptureIntentSnapshot().first)
        #expect(harness.captureMonitoringService.addCallCount == 1)
        #expect(harness.controller.monitoringSession(for: sessionID)?.displayID == display.displayID)
        #expect(lease.kind == .monitor)
        #expect(lease.state == .attached)
        #expect(effectiveIntent.intent.kind == .capture)
        #expect(effectiveIntent.intent.reason == .attach)
        #expect(effectiveIntent.lastApplyResult?.outcome == .applied)
    }

    @Test func monitorStopDetachesRuntimeLeaseAndDrainsPreviewThroughAdapter() async throws {
        let display = SharedMockSCDisplay.make(displayID: 8405, width: 1920, height: 1080)
        let harness = monitorHarness(display: display)
        let actions = CaptureUIComposition.monitoringActions(
            capture: harness.controller,
            displayRuntime: harness.runtime
        )
        let outcome = try await actions.startMonitoring(
            display,
            CaptureMonitoringDisplayMetadata(
                displayName: "Monitor Adapter",
                resolutionText: "1920 × 1080",
                isVirtualDisplay: false
            )
        )
        guard case .started(let sessionID) = outcome else {
            Issue.record("Expected monitor start to succeed.")
            return
        }

        actions.closeMonitoringSession(sessionID)

        let lease = try #require(harness.runtime.currentConsumerLeaseSnapshot().first)
        let effectiveIntent = try #require(harness.runtime.currentEffectiveCaptureIntentSnapshot().first)
        #expect(lease.state == .released)
        #expect(harness.runtime.currentAggregatedDemandSnapshot().isEmpty)
        #expect(effectiveIntent.intent.kind == .drain)
        #expect(effectiveIntent.intent.reason == .detach)
        #expect(effectiveIntent.lastApplyResult?.outcome == .applied)
        #expect(harness.captureMonitoringService.removeByDisplayCallCount == 1)
        #expect(harness.captureMonitoringService.removedDisplayIDs == [display.displayID])
        #expect(harness.controller.screenCaptureSessions.isEmpty)
    }

    @Test func monitorApplyFailsPermissionUnavailableWithoutStartingSession() async {
        let display = SharedMockSCDisplay.make(displayID: 8406, width: 1920, height: 1080)
        let harness = monitorHarness(display: display, hasPermission: false)

        let result = await harness.adapter.applyMonitorCaptureIntent(
            captureIntent(displayID: display.displayID, revision: 3)
        )

        #expect(result.outcome == .failed)
        #expect(result.failureCode == DisplayRuntimeCaptureIntentFailureCode.permissionUnavailable)
        #expect(harness.captureMonitoringService.addCallCount == 0)
        #expect(harness.captureMonitoringService.removeByDisplayCallCount == 0)
        #expect(harness.controller.screenCaptureSessions.isEmpty)
    }

    @Test func monitorApplyFailsDisplayUnavailableWithoutStartingSession() async {
        let display = SharedMockSCDisplay.make(displayID: 8407, width: 1920, height: 1080)
        let harness = monitorHarness(display: display)

        let result = await harness.adapter.applyMonitorCaptureIntent(
            captureIntent(displayID: 8408, revision: 4)
        )

        #expect(result.outcome == .failed)
        #expect(result.failureCode == DisplayRuntimeCaptureIntentFailureCode.displayUnavailable)
        #expect(harness.captureMonitoringService.addCallCount == 0)
        #expect(harness.captureMonitoringService.removeByDisplayCallCount == 0)
        #expect(harness.controller.screenCaptureSessions.isEmpty)
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
        let harness = monitorHarness(display: display)

        let attachResult = await harness.runtime.attachDiagnosticsRecorderConsumer(
            surfaceIdentity: .physicalDisplay(displayID: display.displayID),
            owner: .init(source: .diagnostics, redactedLabel: "recorder"),
            demand: diagnosticsRecorderDemand(display: display)
        )

        let lease = try #require(harness.runtime.currentConsumerLeaseSnapshot().first)
        let effectiveIntent = try #require(harness.runtime.currentEffectiveCaptureIntentSnapshot().first)
        #expect(attachResult.applyResult.outcome == .applied)
        #expect(harness.captureMonitoringService.addCallCount == 1)
        #expect(harness.controller.screenCaptureSessions.first?.displayID == display.displayID)
        #expect(lease.kind == .diagnosticsRecorder)
        #expect(lease.state == .attached)
        #expect(effectiveIntent.intent.kind == .capture)
        #expect(effectiveIntent.intent.aggregateDemand?.consumerKinds == [.diagnosticsRecorder])
        #expect(effectiveIntent.lastApplyResult?.outcome == .applied)

        let detachResult = await harness.runtime.detachDiagnosticsRecorderConsumer(
            leaseID: attachResult.lease.id
        )

        #expect(detachResult.applyResult?.outcome == .applied)
        #expect(harness.captureMonitoringService.removeByDisplayCallCount == 1)
        #expect(harness.controller.screenCaptureSessions.isEmpty)
        #expect(harness.runtime.currentEffectiveCaptureIntentSnapshot().first?.intent.kind == .drain)
    }

    @Test func diagnosticsRecorderReusesExistingMonitorSessionWithoutDuplicateCapture() async throws {
        let display = SharedMockSCDisplay.make(displayID: 8432, width: 1920, height: 1080)
        let harness = monitorHarness(display: display)
        let actions = CaptureUIComposition.monitoringActions(
            capture: harness.controller,
            displayRuntime: harness.runtime
        )
        let outcome = try await actions.startMonitoring(
            display,
            CaptureMonitoringDisplayMetadata(
                displayName: "Monitor Adapter",
                resolutionText: "1920 × 1080",
                isVirtualDisplay: false
            )
        )
        guard case .started(let sessionID) = outcome else {
            Issue.record("Expected monitor start to succeed.")
            return
        }

        let maybeLeaseToken = await actions.attachDiagnosticsRecorder(sessionID)
        let leaseToken = try #require(maybeLeaseToken)
        await actions.detachDiagnosticsRecorder(leaseToken)

        let leases = harness.runtime.currentConsumerLeaseSnapshot()
        let diagnosticsLease = try #require(leases.first { $0.kind == .diagnosticsRecorder })
        let effectiveIntent = try #require(harness.runtime.currentEffectiveCaptureIntentSnapshot().first)
        #expect(harness.captureMonitoringService.addCallCount == 1)
        #expect(harness.captureMonitoringService.removeByDisplayCallCount == 0)
        #expect(leases.filter { $0.kind == .monitor }.first?.state == .attached)
        #expect(diagnosticsLease.state == .released)
        #expect(effectiveIntent.intent.kind == .capture)
        #expect(effectiveIntent.intent.aggregateDemand?.consumerKinds == [.monitor])
        #expect(effectiveIntent.lastApplyResult?.outcome == .applied)
    }

    @Test func diagnosticsRecorderReusesActiveLANWebViewPathWithoutStartingMonitoring() async throws {
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
        #expect(harness.captureController.screenCaptureSessions.isEmpty)
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

    @Test func virtualDisplayAdapterRebuildCallsControllerCommandPath() async throws {
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
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        let result = try await sut.rebuildVirtualDisplay(configID: config.id)

        #expect(facade.rebuildVirtualDisplayCallCount == 1)
        #expect(facade.rebuildVirtualDisplayConfigIds == [config.id])
        #expect(result.configID == config.id)
        #expect(result.preDisplayID == 8302)
        #expect(result.postDisplayID == 8302)
    }

    @Test func virtualDisplayAdapterEnableUsesCommandOnlyPath() async throws {
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
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        _ = try await sut.setVirtualDisplayDesiredEnabled(request: .init(configID: config.id, enabled: true))
        let result = try await sut.enableVirtualDisplay(
            request: .init(configID: config.id, targetPreDisplayID: nil)
        )

        #expect(facade.setDesiredEnabledRequests.map(\.0) == [config.id])
        #expect(facade.enableRuntimeDisplayConfigIDs == [config.id])
        #expect(facade.enableRuntimeDisplayCallCount == 1)
        #expect(result.desiredEnabled == true)
    }

    @Test func virtualDisplayAdapterDisableUsesCommandOnlyPath() async throws {
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
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        _ = try await sut.setVirtualDisplayDesiredEnabled(request: .init(configID: config.id, enabled: false))
        let result = try await sut.disableVirtualDisplay(
            request: .init(configID: config.id, targetPreDisplayID: 8304)
        )

        #expect(facade.setDesiredEnabledRequests.map(\.0) == [config.id])
        #expect(facade.disableRuntimeDisplayByConfigIDs == [config.id])
        #expect(facade.disableRuntimeDisplayByConfigCallCount == 1)
        #expect(result.desiredEnabled == false)
    }

    @Test func virtualDisplayAdapterSaveConfigForRebuildUsesCommandOnlyPathAndReturnsPreviousConfig() async throws {
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
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

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
        #expect(result.persistenceOutcome == .saved)
        #expect(result.previousConfigForCompensation.displayName == "Old Adapter Name")
        #expect(result.savedConfigEvidence.serialNumber == 9305)
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
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

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

    @Test func virtualDisplayAdapterCommandOnlySaveFailureDoesNotSetPersistenceAlert() async throws {
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
        facade.saveConfigForRebuildError = NSError(domain: "CommandOnlySave", code: 7)
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

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

    @Test func virtualDisplayAdapterRestoreConfigAfterFailedEditUsesPreviousConfigCommandPath() async throws {
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
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

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

    @Test func virtualDisplayAdapterCreateUsesCommandOnlyPathAndMapsFacts() async throws {
        let createdID = UUID()
        let facade = MockVirtualDisplayFacade()
        facade.createDisplayResult = .success(createdID)
        facade.runtimeDisplayIDByConfigId[createdID] = 8310
        facade.currentRunningConfigIds = [createdID]
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        let result = try await sut.createVirtualDisplay(
            request: runtimeCreateRequest(displayName: "Adapter Secret", serialNumber: 9310)
        )

        #expect(facade.createDisplayCommandCallCount == 1)
        #expect(facade.createDisplayCommandSerialNumbers == [9310])
        #expect(result.createdConfigID == createdID)
        #expect(result.persistenceOutcome == .saved)
        #expect(result.runtimeCreationOutcome == .succeeded)
        #expect(result.rollbackOutcome == .notAttempted)
        #expect(controller.persistenceAlert == nil)
    }

    @Test func virtualDisplayAdapterCreateReportsRollbackFailureWithoutSnapshotDiffGuessing() async throws {
        let createdID = UUID()
        let facade = MockVirtualDisplayFacade()
        facade.createDisplayResult = .failure(
            VirtualDisplayCreateCommandFailure(
                reason: "persistenceRecoveryFailed",
                result: VirtualDisplayCreateCommandResult(
                    createdConfigID: createdID,
                    serialNumber: 9311,
                    targetWasRunningAfterCommand: false,
                    preDisplayID: nil,
                    postDisplayID: nil,
                    persistenceOutcome: .rollbackFailed,
                    runtimeCreationOutcome: .failed,
                    rollbackOutcome: .rollbackFailed,
                    createdConfigEvidence: .init(
                        id: createdID,
                        serialNumber: 9311,
                        desiredEnabled: true,
                        physicalWidthMillimeters: 600,
                        physicalHeightMillimeters: 340,
                        modeCount: 1,
                        maximumPixelWidth: 1920,
                        maximumPixelHeight: 1080
                    ),
                    runningConfigIDsAfterCommand: [],
                    managedDisplaysAfterCommand: []
                ),
                underlyingError: NSError(domain: "Create", code: 11)
            )
        )
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        await #expect(throws: DisplayRuntimeVirtualDisplayCreateCommandError.self) {
            _ = try await sut.createVirtualDisplay(
                request: runtimeCreateRequest(displayName: "Adapter Rollback", serialNumber: 9311)
            )
        }
        #expect(facade.createDisplayCommandCallCount == 1)
        #expect(controller.persistenceAlert == nil)
    }

    @Test func virtualDisplayAdapterDeleteUsesCommandOnlyPathAndMapsFacts() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Delete Adapter",
            serialNum: 9312,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        facade.currentRunningConfigIds = [config.id]
        facade.runtimeDisplayIDByConfigId[config.id] = 8312
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        let result = try await sut.deleteVirtualDisplay(
            request: .init(
                transactionID: DisplayRuntimeTransactionID(),
                configID: config.id,
                targetPreDisplayID: 8312,
                targetWasRunning: true
            )
        )

        #expect(facade.destroyDisplayByConfigCallCount == 1)
        #expect(facade.destroyedConfigIDs == [config.id])
        #expect(result.targetWasRunning)
        #expect(result.preDisplayID == 8312)
        #expect(result.runtimeTrackingClearOutcome == .cleared)
        #expect(controller.persistenceAlert == nil)
    }

    @Test func virtualDisplayAdapterDeleteDoesNotMapMissingConfigToSuccess() async throws {
        let configID = UUID()
        let facade = MockVirtualDisplayFacade()
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        do {
            _ = try await sut.deleteVirtualDisplay(
                request: .init(
                    transactionID: DisplayRuntimeTransactionID(),
                    configID: configID,
                    targetPreDisplayID: nil,
                    targetWasRunning: false
                )
            )
            Issue.record("Expected config_not_found failure.")
        } catch let error as DisplayRuntimeVirtualDisplayDeleteCommandError {
            #expect(error.reason == "config_not_found")
            #expect(error.result.persistenceOutcome == .notAttempted)
            #expect(error.result.virtualDisplayCommandOutcome == .failed)
            #expect(error.result.runtimeTrackingClearOutcome == .notAttempted)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        #expect(facade.destroyDisplayByConfigCallCount == 1)
        #expect(controller.persistenceAlert == nil)
    }

    @Test func virtualDisplayAdapterUnavailableFailsExplicitly() async throws {
        var controller: VirtualDisplayController? = VirtualDisplayController(
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller!)
        controller = nil

        await #expect(throws: (any Error).self) {
            _ = try await sut.enableVirtualDisplay(
                request: .init(configID: UUID(), targetPreDisplayID: nil)
            )
        }
    }
}

private final class AdapterTestPortPreferences: SharingPortPreferencesProtocol {
    var preferredPort: UInt16 = 8081

    func savePreferredPort(_ port: UInt16) {
        preferredPort = port
    }
}

private final class AdapterMonitorDummySession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let shareFrameConsumer: any DisplayShareFrameConsumer = TestDisplayShareFrameConsumer()

    nonisolated func attachPreviewSink(_: any DisplayPreviewSink) {}

    nonisolated func detachPreviewSink(_: any DisplayPreviewSink) {}

    nonisolated func stopSharing() {}

    nonisolated func stop() async {}
}

@MainActor
private func monitorHarness(
    display: SCDisplay,
    hasPermission: Bool = true
) -> (
    catalogService: ScreenCaptureCatalogService,
    captureMonitoringService: MockCaptureMonitoringService,
    controller: CaptureController,
    adapter: DisplayRuntimeCaptureAdapter,
    runtime: DisplayRuntime
) {
    let catalogService = ScreenCaptureCatalogService(
        permissionProvider: FailingScreenCapturePermissionProvider(),
        loadShareableDisplays: {
            Issue.record("Monitor wiring tests must not load real shareable displays.")
            return [display]
        },
        activeDisplayIDsProvider: { [display.displayID] }
    )
    catalogService.store.hasScreenCapturePermission = hasPermission
    catalogService.store.lastPreflightPermission = hasPermission
    catalogService.store.displays = [display]

    let captureMonitoringService = MockCaptureMonitoringService()
    let lifecycleService = CaptureMonitoringLifecycleService(
        captureMonitoringService: captureMonitoringService,
        acquirePreview: { captureDisplay, _ in
            .started(
                DisplayPreviewSubscription(
                    displayID: captureDisplay.displayID,
                    resolutionText: "\(captureDisplay.width) × \(captureDisplay.height)",
                    session: AdapterMonitorDummySession(),
                    cancelClosure: {}
                )
            )
        }
    )
    let controller = CaptureController(
        captureMonitoringService: captureMonitoringService,
        captureMonitoringLifecycleService: lifecycleService,
        catalogService: catalogService
    )
    let adapter = DisplayRuntimeCaptureAdapter(controller: controller)
    let runtime = DisplayRuntime(
        catalogProvider: DisplayRuntimeCatalogAdapter(service: catalogService),
        captureProvider: adapter,
        captureIntentCommander: adapter
    )
    return (
        catalogService: catalogService,
        captureMonitoringService: captureMonitoringService,
        controller: controller,
        adapter: adapter,
        runtime: runtime
    )
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
        captureMonitoringService: MockCaptureMonitoringService(),
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
    let maxPixels = config.maxPixelDimensions
    return DisplayRuntimeVirtualDisplayConfigEditDTO(
        id: config.id,
        displayName: config.displayName,
        serialNumber: config.serialNum,
        desiredEnabled: config.desiredEnabled,
        physicalWidthMillimeters: UInt32(clamping: config.physicalWidth),
        physicalHeightMillimeters: UInt32(clamping: config.physicalHeight),
        modes: config.modes.map {
            .init(
                width: $0.width,
                height: $0.height,
                refreshRate: $0.refreshRate,
                enableHiDPI: $0.enableHiDPI
            )
        },
        maximumPixelWidth: maxPixels.width,
        maximumPixelHeight: maxPixels.height
    )
}

private func runtimeCreateRequest(
    displayName: String,
    serialNumber: UInt32
) -> DisplayRuntimeVirtualDisplayCreateRequest {
    .init(
        displayName: displayName,
        serialNumber: serialNumber,
        physicalWidthMillimeters: 600,
        physicalHeightMillimeters: 340,
        maximumPixelWidth: 1920,
        maximumPixelHeight: 1080,
        modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
        source: .createVirtualDisplaySheet
    )
}
