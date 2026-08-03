@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeCatalogControlTests {
    @Test func captureAppearRefreshesAndConvergesVisibleDisplays() async {
        let removedDisplayID = DisplayRuntimeDisplayID(1001)
        let keptDisplayID = DisplayRuntimeDisplayID(1002)
        let catalog = FakeCatalogCommander(
            snapshot: catalogSnapshot(displayID: keptDisplayID, isMain: false),
            refreshResults: [.reloadedSnapshot],
        )
        let capture = FakeCaptureCommander(
            snapshot: captureSnapshot(displayIDs: [removedDisplayID, keptDisplayID])
        )
        let sharing = FakeSharingCommander(
            snapshot: sharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [removedDisplayID, keptDisplayID])
        )
        let virtualDisplay = FakeVirtualDisplayProvider(
            snapshot: virtualDisplaySnapshot(
                configs: [(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, 9002, keptDisplayID)]
            )
        )
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = makeRuntime(
            catalog: catalog,
            capture: capture,
            sharing: sharing,
            virtualDisplay: virtualDisplay,
            captureIntentCommander: captureIntentCommander
        )
        let removedSurface = DisplaySurfaceIdentity.physicalDisplay(displayID: removedDisplayID)
        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: removedSurface,
            kind: .preview,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand()
        )
        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: removedSurface,
            kind: .lanWebView,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand()
        )

        let registration = runtime.registerCatalogSurface(source: .capturePage)
        await runtime.refreshCatalogSurface(registration)

        #expect(catalog.submitCalls == [.init(intent: .permissionChanged)])
        #expect(sharing.registeredDisplays == [[
            .init(displayID: keptDisplayID, virtualSerialNumber: 9002)
        ]])
        #expect(captureIntentCommander.intents.suffix(2).allSatisfy { $0.kind == .drain })
        #expect(runtime.currentConsumerLeaseSnapshot().allSatisfy { $0.state == .failed })
    }

    @Test func sharingAppearWithStoppedServiceSkipsRefreshWithoutClearingSnapshot() async {
        let catalog = FakeCatalogCommander(
            snapshot: catalogSnapshot(displayID: 2001, isMain: false),
            refreshResults: [.reloadedSnapshot],
        )
        let sharing = FakeSharingCommander(
            snapshot: sharingSnapshot(isWebServiceRunning: false, activeDisplayIDs: [])
        )
        let runtime = makeRuntime(catalog: catalog, sharing: sharing)

        let registration = runtime.registerCatalogSurface(source: .sharingPage)
        await runtime.refreshCatalogSurface(registration)

        #expect(catalog.submitCalls.isEmpty)
        #expect(catalog.clearLoadErrorMessages.isEmpty)
        #expect(sharing.registeredDisplays.isEmpty)
    }

    @Test func sharingServiceStartReusesSnapshotAndRegistersShareableDisplays() async {
        let displayID = DisplayRuntimeDisplayID(3001)
        let catalog = FakeCatalogCommander(
            snapshot: catalogSnapshot(displayID: displayID, isMain: false),
            refreshResults: [.reusedSnapshot],
        )
        let sharing = FakeSharingCommander(
            snapshot: sharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [])
        )
        let runtime = makeRuntime(catalog: catalog, sharing: sharing)

        await runtime.handleSharingServiceStateChanged(isRunning: false)

        #expect(catalog.submitCalls == [.init(intent: .serviceBecameRunning)])
        #expect(sharing.registeredDisplays == [[
            .init(displayID: displayID, virtualSerialNumber: nil)
        ]])
    }

    @Test func permissionDeniedClearsSnapshotAndStopsInvalidSessions() async {
        let removedDisplayID = DisplayRuntimeDisplayID(4001)
        let catalog = FakeCatalogCommander(
            snapshot: catalogSnapshot(displayID: removedDisplayID, isMain: false),
            refreshPermissionResults: [false],
            refreshResults: [.reloadedSnapshot],
        )
        let capture = FakeCaptureCommander(snapshot: captureSnapshot(displayIDs: [removedDisplayID]))
        let sharing = FakeSharingCommander(
            snapshot: sharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [removedDisplayID])
        )
        let observability = FakeObservabilityRecorder()
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = makeRuntime(
            catalog: catalog,
            capture: capture,
            sharing: sharing,
            observability: observability,
            captureIntentCommander: captureIntentCommander
        )
        let removedSurface = DisplaySurfaceIdentity.physicalDisplay(displayID: removedDisplayID)
        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: removedSurface,
            kind: .preview,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand()
        )
        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: removedSurface,
            kind: .lanWebView,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand()
        )

        await runtime.refreshCatalogPermission(source: .capturePage)

        #expect(catalog.clearLoadErrorMessages == [nil])
        #expect(sharing.registeredDisplays == [[]])
        #expect(captureIntentCommander.intents.suffix(2).allSatisfy { $0.kind == .drain })
        #expect(runtime.currentConsumerLeaseSnapshot().allSatisfy { $0.state == .failed })
        #expect(observability.events.map(\.deduplicationKey).contains("screenCatalog.permission.denied"))
        #expect(observability.refreshReasons == [.screenCatalogStateChanged])
    }

    @Test func forcedPermissionDenialReturnsTheCommanderClearSettlement() async {
        let staleCatalog = catalogSnapshot(displayID: 4051, isMain: false)
        let catalog = FakeCatalogCommander(
            snapshot: staleCatalog,
            refreshPermissionResults: [false],
        )
        let runtime = makeRuntime(catalog: catalog)

        let outcome = await runtime.forceRefreshCatalog(source: .capturePage)

        #expect(outcome.settlementID == 1)
        #expect(outcome.result == .clearedSnapshot)
        #expect(outcome.catalog.hasScreenCapturePermission == false)
        #expect(outcome.catalog.lastPreflightPermission == false)
        #expect(outcome.catalog.loadedDisplays.isEmpty)
        #expect(catalog.clearLoadErrorMessages == [nil])
    }

    @Test func sharingPermissionRequestDeniedPassesLoadErrorMessage() async {
        let catalog = FakeCatalogCommander()
        catalog.requestPermissionResult = false
        let runtime = makeRuntime(catalog: catalog)

        await runtime.requestCatalogPermission(source: .sharingPage)

        #expect(catalog.clearLoadErrorMessages == [
            String(localized: "Failed to load displays. Check permission and try again.")
        ])
        #expect(catalog.submitCalls.isEmpty)
    }

    @Test func topologyChangeCoalescesAndAppliesLatestVisibleDisplays() async {
        let firstDisplayID = DisplayRuntimeDisplayID(5001)
        let secondDisplayID = DisplayRuntimeDisplayID(5002)
        let catalog = FakeCatalogCommander(
            snapshot: catalogSnapshot(displayID: firstDisplayID, isMain: false),
            refreshResults: [.reloadedSnapshot],
        )
        catalog.shouldGateSubmitRefresh = true
        let sharing = FakeSharingCommander(
            snapshot: sharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [])
        )
        let runtime = makeRuntime(catalog: catalog, sharing: sharing)

        let firstRefresh = Task { await runtime.handleCatalogTopologyChanged() }
        await catalog.waitForSubmitCalls(1)

        catalog.snapshot = catalogSnapshot(displayID: secondDisplayID, isMain: false)
        let secondRefresh = Task { await runtime.handleCatalogTopologyChanged() }
        catalog.releaseSubmitRefresh(call: 1)

        await catalog.waitForSubmitCalls(2)
        catalog.releaseSubmitRefresh(call: 2)
        await firstRefresh.value
        await secondRefresh.value

        #expect(catalog.submitCalls == [
            .init(intent: .topologyChanged),
            .init(intent: .topologyChanged),
        ])
        #expect(sharing.registeredDisplays.last == [
            .init(displayID: secondDisplayID, virtualSerialNumber: nil)
        ])
    }

    @Test func failedRefreshSkipsConvergence() async {
        let catalog = FakeCatalogCommander(
            snapshot: catalogSnapshot(displayID: 6001, isMain: false),
            refreshResults: [.failed],
        )
        let capture = FakeCaptureCommander(snapshot: captureSnapshot(displayIDs: [6002]))
        let sharing = FakeSharingCommander(
            snapshot: sharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [6002])
        )
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = makeRuntime(
            catalog: catalog,
            capture: capture,
            sharing: sharing,
            captureIntentCommander: captureIntentCommander
        )
        let staleSurface = DisplaySurfaceIdentity.physicalDisplay(displayID: 6002)
        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: staleSurface,
            kind: .preview,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand()
        )
        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: staleSurface,
            kind: .lanWebView,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand()
        )

        let outcome = await runtime.forceRefreshCatalog(source: .capturePage)

        #expect(outcome.result == .failed)
        #expect(outcome.catalog == runtime.makeSnapshot().catalog)
        #expect(catalog.submitCalls == [.init(intent: .userForcedRefresh)])
        #expect(sharing.registeredDisplays.isEmpty)
        #expect(captureIntentCommander.intents.count == 2)
        #expect(runtime.currentConsumerLeaseSnapshot().allSatisfy { $0.state == .attached })
    }

    @Test func supersededRefreshSkipsConvergenceWithoutReportingFailure() async {
        let catalog = FakeCatalogCommander(
            snapshot: catalogSnapshot(displayID: 6251, isMain: false),
            refreshResults: [.superseded],
        )
        let sharing = FakeSharingCommander(
            snapshot: sharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [])
        )
        let runtime = makeRuntime(catalog: catalog, sharing: sharing)

        let outcome = await runtime.forceRefreshCatalog(source: .capturePage)

        #expect(outcome.result == .superseded)
        #expect(outcome.catalog == runtime.makeSnapshot().catalog)
        #expect(catalog.submitCalls == [.init(intent: .userForcedRefresh)])
        #expect(sharing.registeredDisplays.isEmpty)
    }

    @Test func forcedCaptureRefreshRegistersLatestDisplaysForRunningSharingService() async {
        let displayID = DisplayRuntimeDisplayID(6301)
        let catalog = FakeCatalogCommander(
            snapshot: catalogSnapshot(displayID: displayID, isMain: false),
            refreshResults: [.reloadedSnapshot],
        )
        let sharing = FakeSharingCommander(
            snapshot: sharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [])
        )
        let runtime = makeRuntime(catalog: catalog, sharing: sharing)

        let outcome = await runtime.forceRefreshCatalog(source: .capturePage)

        #expect(outcome.result == .reloadedSnapshot)
        #expect(catalog.submitCalls == [.init(intent: .userForcedRefresh)])
        #expect(sharing.registeredDisplays == [[
            .init(displayID: displayID, virtualSerialNumber: nil)
        ]])
    }

    @Test func forcedRefreshOutcomeUsesTheCommanderCommittedCatalog() async {
        let committedCatalog = catalogSnapshot(displayID: 6401, isMain: false)
        let unrelatedCatalog = catalogSnapshot(displayID: 6402, isMain: false)
        let catalogProvider = FakeCatalogProvider(snapshot: committedCatalog)
        let catalogCommander = FakeCatalogCommander(
            snapshot: committedCatalog,
            refreshResults: [.reloadedSnapshot],
        )
        let observability = FakeObservabilityRecorder {
            catalogProvider.setSnapshot(unrelatedCatalog)
        }
        let runtime = DisplayRuntime(
            catalogProvider: catalogProvider,
            catalogCommander: catalogCommander,
            observabilityRecorder: observability
        )

        let outcome = await runtime.forceRefreshCatalog(source: .capturePage)

        #expect(outcome.result == .reloadedSnapshot)
        #expect(outcome.catalog == committedCatalog)
        #expect(runtime.makeSnapshot().catalog == unrelatedCatalog)
    }

    @Test func forcedRefreshOutcomeKeepsTheCommanderCatalogAtomic() async {
        let committedCatalog = catalogSnapshot(displayID: 6411, isMain: false)
        let unrelatedCatalog = catalogSnapshot(displayID: 6412, isMain: false)
        let catalogProvider = FakeCatalogProvider(snapshot: unrelatedCatalog)
        let catalogCommander = FakeCatalogCommander(
            snapshot: committedCatalog,
            refreshResults: [.reloadedSnapshot],
        )
        let runtime = DisplayRuntime(
            catalogProvider: catalogProvider,
            catalogCommander: catalogCommander
        )

        let outcome = await runtime.forceRefreshCatalog(source: .capturePage)

        #expect(outcome.result == .reloadedSnapshot)
        #expect(outcome.catalog == committedCatalog)
    }

    @Test func olderSettlementCannotOverwriteNewerCatalogConvergence() async {
        let olderDisplayID = DisplayRuntimeDisplayID(6421)
        let newerDisplayID = DisplayRuntimeDisplayID(6422)
        let sharing = FakeSharingCommander(
            snapshot: sharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [])
        )
        let runtime = DisplayRuntime(
            sharingProvider: sharing,
            sharingCommander: sharing
        )

        await runtime.handleRefreshOutcomeForConvergence(
            .init(
                settlementID: 2,
                result: .reloadedSnapshot,
                catalog: catalogSnapshot(displayID: newerDisplayID, isMain: false)
            )
        )
        await runtime.handleRefreshOutcomeForConvergence(
            .init(
                settlementID: 1,
                result: .reloadedSnapshot,
                catalog: catalogSnapshot(displayID: olderDisplayID, isMain: false)
            )
        )

        #expect(sharing.registeredDisplays == [[
            .init(displayID: newerDisplayID, virtualSerialNumber: nil)
        ]])
    }

    @Test func failedSettlementDoesNotSuppressEarlierSuccessfulConvergence() async {
        let displayID = DisplayRuntimeDisplayID(6423)
        let sharing = FakeSharingCommander(
            snapshot: sharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [])
        )
        let runtime = DisplayRuntime(
            sharingProvider: sharing,
            sharingCommander: sharing
        )

        await runtime.handleRefreshOutcomeForConvergence(
            .init(settlementID: 2, result: .failed, catalog: .empty)
        )
        await runtime.handleRefreshOutcomeForConvergence(
            .init(
                settlementID: 1,
                result: .reloadedSnapshot,
                catalog: catalogSnapshot(displayID: displayID, isMain: false)
            )
        )

        #expect(sharing.registeredDisplays == [[
            .init(displayID: displayID, virtualSerialNumber: nil)
        ]])
    }

    @Test func catalogRegistrationCannotUnregisterAnotherActiveSurface() async {
        let catalog = FakeCatalogCommander()
        let runtime = makeRuntime(catalog: catalog)

        let firstRegistration = runtime.registerCatalogSurface(source: .capturePage)
        let secondRegistration = runtime.registerCatalogSurface(source: .capturePage)

        await runtime.unregisterCatalogSurface(firstRegistration)
        #expect(catalog.submitCalls.isEmpty)

        await runtime.unregisterCatalogSurface(firstRegistration)
        #expect(catalog.submitCalls.isEmpty)

        await runtime.unregisterCatalogSurface(secondRegistration)
        #expect(catalog.submitCalls.isEmpty)
    }

    @Test func clearedRefreshResultConvergesWithEmptyVisibleDisplays() async {
        let staleDisplayID = DisplayRuntimeDisplayID(6501)
        let catalog = FakeCatalogCommander(
            refreshResults: [.clearedSnapshot],
        )
        let capture = FakeCaptureCommander(snapshot: captureSnapshot(displayIDs: [staleDisplayID]))
        let sharing = FakeSharingCommander(
            snapshot: sharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [staleDisplayID])
        )
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = makeRuntime(
            catalog: catalog,
            capture: capture,
            sharing: sharing,
            captureIntentCommander: captureIntentCommander
        )
        let staleSurface = DisplaySurfaceIdentity.physicalDisplay(displayID: staleDisplayID)
        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: staleSurface,
            kind: .preview,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand()
        )
        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: staleSurface,
            kind: .lanWebView,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand()
        )

        let outcome = await runtime.forceRefreshCatalog(source: .capturePage)

        #expect(outcome.result == .clearedSnapshot)
        #expect(outcome.catalog == runtime.makeSnapshot().catalog)
        #expect(sharing.registeredDisplays == [[]])
        #expect(captureIntentCommander.intents.suffix(2).allSatisfy { $0.kind == .drain })
        #expect(runtime.currentConsumerLeaseSnapshot().allSatisfy { $0.state == .failed })
    }

    @Test func sharingServiceStateChangeReadsCurrentSharingSnapshot() async {
        let catalog = FakeCatalogCommander(
            snapshot: catalogSnapshot(displayID: 7001, isMain: false),
            refreshResults: [.reloadedSnapshot],
        )
        let sharing = FakeSharingCommander(
            snapshot: sharingSnapshot(isWebServiceRunning: false, activeDisplayIDs: [])
        )
        let runtime = makeRuntime(catalog: catalog, sharing: sharing)

        await runtime.handleSharingServiceStateChanged(isRunning: true)

        #expect(catalog.submitCalls.isEmpty)
        #expect(sharing.registeredDisplays.isEmpty)
    }

    @Test func forcedSharingRefreshWithStoppedServiceReportsFailure() async {
        let catalog = FakeCatalogCommander(
            snapshot: catalogSnapshot(displayID: 7101, isMain: false),
            refreshResults: [.reloadedSnapshot],
        )
        let sharing = FakeSharingCommander(
            snapshot: sharingSnapshot(isWebServiceRunning: false, activeDisplayIDs: [])
        )
        let runtime = makeRuntime(catalog: catalog, sharing: sharing)

        let outcome = await runtime.forceRefreshCatalog(source: .sharingPage)

        #expect(outcome.result == .failed)
        #expect(outcome.catalog == runtime.makeSnapshot().catalog)
        #expect(catalog.submitCalls.isEmpty)
        #expect(sharing.registeredDisplays.isEmpty)
    }
}

@MainActor
private func makeRuntime(
    catalog: FakeCatalogCommander,
    capture: FakeCaptureCommander = FakeCaptureCommander(),
    sharing: FakeSharingCommander = FakeSharingCommander(),
    virtualDisplay: FakeVirtualDisplayProvider = FakeVirtualDisplayProvider(snapshot: .empty),
    observability: FakeObservabilityRecorder = FakeObservabilityRecorder(),
    captureIntentCommander: FakeCaptureIntentCommander? = nil
) -> DisplayRuntime {
    DisplayRuntime(
        catalogProvider: catalog,
        captureProvider: capture,
        sharingProvider: sharing,
        virtualDisplayProvider: virtualDisplay,
        catalogCommander: catalog,
        sharingCommander: sharing,
        captureIntentCommander: captureIntentCommander,
        observabilityRecorder: observability
    )
}
