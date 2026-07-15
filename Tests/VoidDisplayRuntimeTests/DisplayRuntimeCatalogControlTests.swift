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
            refreshResults: [.reloadedSnapshot],
            visibleDisplays: [.init(displayID: keptDisplayID, pixelWidth: 2560, pixelHeight: 1440)]
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

        await runtime.handleCatalogAppear(source: .capturePage)

        #expect(catalog.submitCalls == [.init(intent: .permissionChanged, ownerScope: .capture)])
        #expect(sharing.registeredDisplays == [[
            .init(displayID: keptDisplayID, virtualSerialNumber: 9002)
        ]])
        #expect(captureIntentCommander.intents.suffix(2).allSatisfy { $0.kind == .drain })
        #expect(runtime.currentConsumerLeaseSnapshot().allSatisfy { $0.state == .failed })
    }

    @Test func sharingAppearWithStoppedServiceCancelsRefreshWithoutClearingSnapshot() async {
        let catalog = FakeCatalogCommander(
            refreshResults: [.reloadedSnapshot],
            visibleDisplays: [.init(displayID: 2001, pixelWidth: 1920, pixelHeight: 1080)]
        )
        let sharing = FakeSharingCommander(
            snapshot: sharingSnapshot(isWebServiceRunning: false, activeDisplayIDs: [])
        )
        let runtime = makeRuntime(catalog: catalog, sharing: sharing)

        await runtime.handleCatalogAppear(source: .sharingPage)

        #expect(catalog.submitCalls.isEmpty)
        #expect(catalog.cancelledOwnerScopes == [.sharing])
        #expect(catalog.clearLoadErrorMessages.isEmpty)
        #expect(sharing.registeredDisplays.isEmpty)
    }

    @Test func sharingServiceStartReusesSnapshotAndRegistersShareableDisplays() async {
        let displayID = DisplayRuntimeDisplayID(3001)
        let catalog = FakeCatalogCommander(
            refreshResults: [.reusedSnapshot],
            visibleDisplays: [.init(displayID: displayID, pixelWidth: 2560, pixelHeight: 1440)]
        )
        let sharing = FakeSharingCommander(
            snapshot: sharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [])
        )
        let runtime = makeRuntime(catalog: catalog, sharing: sharing)

        await runtime.handleSharingServiceStateChanged(isRunning: false)

        #expect(catalog.submitCalls == [.init(intent: .serviceBecameRunning, ownerScope: .sharing)])
        #expect(sharing.registeredDisplays == [[
            .init(displayID: displayID, virtualSerialNumber: nil)
        ]])
    }

    @Test func permissionDeniedClearsSnapshotAndStopsInvalidSessions() async {
        let removedDisplayID = DisplayRuntimeDisplayID(4001)
        let catalog = FakeCatalogCommander(
            refreshPermissionResults: [false],
            refreshResults: [.reloadedSnapshot],
            visibleDisplays: [.init(displayID: removedDisplayID, pixelWidth: 1920, pixelHeight: 1080)]
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
            refreshResults: [.reloadedSnapshot],
            visibleDisplays: [.init(displayID: firstDisplayID, pixelWidth: 1920, pixelHeight: 1080)]
        )
        catalog.shouldGateSubmitRefresh = true
        let sharing = FakeSharingCommander(
            snapshot: sharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [])
        )
        let runtime = makeRuntime(catalog: catalog, sharing: sharing)

        let firstRefresh = Task { await runtime.handleCatalogTopologyChanged() }
        await catalog.waitForSubmitCalls(1)

        catalog.visibleDisplays = [.init(displayID: secondDisplayID, pixelWidth: 2560, pixelHeight: 1440)]
        let secondRefresh = Task { await runtime.handleCatalogTopologyChanged() }
        catalog.releaseSubmitRefresh(call: 1)

        await catalog.waitForSubmitCalls(2)
        catalog.releaseSubmitRefresh(call: 2)
        await firstRefresh.value
        await secondRefresh.value

        #expect(catalog.submitCalls == [
            .init(intent: .topologyChanged, ownerScope: nil),
            .init(intent: .topologyChanged, ownerScope: nil),
        ])
        #expect(sharing.registeredDisplays.last == [
            .init(displayID: secondDisplayID, virtualSerialNumber: nil)
        ])
    }

    @Test func failedRefreshSkipsConvergence() async {
        let catalog = FakeCatalogCommander(
            refreshResults: [.failed],
            visibleDisplays: [.init(displayID: 6001, pixelWidth: 1920, pixelHeight: 1080)]
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

        await runtime.forceRefreshCatalog(source: .capturePage)

        #expect(catalog.submitCalls == [.init(intent: .userForcedRefresh, ownerScope: .capture)])
        #expect(sharing.registeredDisplays.isEmpty)
        #expect(captureIntentCommander.intents.count == 2)
        #expect(runtime.currentConsumerLeaseSnapshot().allSatisfy { $0.state == .attached })
    }

    @Test func clearedRefreshResultConvergesWithEmptyVisibleDisplays() async {
        let staleDisplayID = DisplayRuntimeDisplayID(6501)
        let catalog = FakeCatalogCommander(
            refreshResults: [.clearedSnapshot],
            visibleDisplays: [.init(displayID: staleDisplayID, pixelWidth: 1920, pixelHeight: 1080)]
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

        await runtime.forceRefreshCatalog(source: .capturePage)

        #expect(sharing.registeredDisplays == [[]])
        #expect(captureIntentCommander.intents.suffix(2).allSatisfy { $0.kind == .drain })
        #expect(runtime.currentConsumerLeaseSnapshot().allSatisfy { $0.state == .failed })
    }

    @Test func sharingServiceStateChangeReadsCurrentSharingSnapshot() async {
        let catalog = FakeCatalogCommander(
            refreshResults: [.reloadedSnapshot],
            visibleDisplays: [.init(displayID: 7001, pixelWidth: 1920, pixelHeight: 1080)]
        )
        let sharing = FakeSharingCommander(
            snapshot: sharingSnapshot(isWebServiceRunning: false, activeDisplayIDs: [])
        )
        let runtime = makeRuntime(catalog: catalog, sharing: sharing)

        await runtime.handleSharingServiceStateChanged(isRunning: true)

        #expect(catalog.submitCalls.isEmpty)
        #expect(catalog.cancelledOwnerScopes == [.sharing])
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
