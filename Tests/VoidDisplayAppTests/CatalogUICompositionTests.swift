@testable import VoidDisplayApp
@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct CatalogUICompositionTests {
    @Test func captureCatalogActionsDispatchToRuntimeCatalogControl() async {
        let harness = CatalogCompositionHarness(isWebServiceRunning: true)
        let actions = CaptureUIComposition.catalogActions(
            displayRuntime: harness.runtime,
            openScreenCapturePrivacySettings: harness.openPrivacySettings
        )

        await actions.handleAppear()
        await actions.handleDisappear()
        await actions.requestPermission()
        await actions.refreshPermission()
        await actions.forceRefresh()
        await actions.handleTopologyChanged()
        actions.openScreenCapturePrivacySettings { harness.openedURL = $0 }

        #expect(harness.catalog.requestPermissionCallCount == 1)
        #expect(harness.catalog.refreshPermissionCallCount == 4)
        #expect(harness.catalog.submitCalls == [
            .init(intent: .permissionChanged, ownerScope: .capture),
            .init(intent: .permissionChanged, ownerScope: .capture),
            .init(intent: .permissionChanged, ownerScope: .capture),
            .init(intent: .userForcedRefresh, ownerScope: .capture),
            .init(intent: .topologyChanged, ownerScope: nil)
        ])
        #expect(harness.catalog.cancelCalls == [.capture])
        #expect(harness.openedURL == harness.expectedPrivacyURL)
    }

    @Test func sharingCatalogActionsDispatchToRuntimeCatalogControl() async {
        let harness = CatalogCompositionHarness(isWebServiceRunning: true)
        let actions = SharingUIComposition.catalogActions(
            displayRuntime: harness.runtime,
            openScreenCapturePrivacySettings: harness.openPrivacySettings
        )

        await actions.handleAppear()
        await actions.handleDisappear()
        await actions.requestPermission()
        await actions.refreshPermission()
        await actions.forceRefresh()
        await actions.handleTopologyChanged()
        await actions.handleSharingServiceStateChanged(true)
        actions.openScreenCapturePrivacySettings { harness.openedURL = $0 }

        #expect(harness.catalog.requestPermissionCallCount == 1)
        #expect(harness.catalog.refreshPermissionCallCount == 8)
        #expect(harness.catalog.submitCalls == [
            .init(intent: .serviceBecameRunning, ownerScope: .sharing),
            .init(intent: .serviceBecameRunning, ownerScope: .sharing),
            .init(intent: .serviceBecameRunning, ownerScope: .sharing),
            .init(intent: .userForcedRefresh, ownerScope: .sharing),
            .init(intent: .topologyChanged, ownerScope: nil),
            .init(intent: .serviceBecameRunning, ownerScope: .sharing)
        ])
        #expect(harness.catalog.cancelCalls == [.sharing])
        #expect(harness.openedURL == harness.expectedPrivacyURL)
    }
}

private struct CatalogSubmitCall: Equatable {
    let intent: DisplayRuntimeCatalogRefreshIntent
    let ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?
}

@MainActor
private final class CatalogCompositionHarness {
    let expectedPrivacyURL = URL(string: "x-voiddisplay-test://privacy")!
    let catalog = CatalogForwardingHarness()
    let runtime: DisplayRuntime
    var openedURL: URL?

    init(isWebServiceRunning: Bool) {
        let sharing = SharingForwardingHarness(
            snapshot: DisplayRuntimeSharingSnapshot(
                activeSharingDisplayIDs: [],
                startingDisplayIDs: [],
                isSharing: false,
                isWebServiceRunning: isWebServiceRunning,
                preferredPort: 8081,
                sharingClientCount: 0,
                sharingClientCounts: [],
                lifecycle: .init(
                    phase: isWebServiceRunning ? .running : .stopped,
                    requestedPort: isWebServiceRunning ? 8081 : nil,
                    boundPort: isWebServiceRunning ? 8081 : nil,
                    failureReason: nil,
                    hasFailureMessage: false
                ),
                routes: []
            )
        )
        runtime = DisplayRuntime(
            catalogProvider: catalog,
            sharingProvider: sharing,
            catalogCommander: catalog,
            sharingCommander: sharing
        )
    }

    func openPrivacySettings(_ openURL: @escaping (URL) -> Void) {
        openURL(expectedPrivacyURL)
    }
}

@MainActor
private final class CatalogForwardingHarness: DisplayRuntimeCatalogProviding, DisplayRuntimeCatalogCommanding {
    private(set) var requestPermissionCallCount = 0
    private(set) var refreshPermissionCallCount = 0
    private(set) var submitCalls: [CatalogSubmitCall] = []
    private(set) var cancelCalls: [DisplayRuntimeCatalogRefreshOwnerScope?] = []

    func makeCatalogSnapshot() -> DisplayRuntimeCatalogSnapshot {
        .empty
    }

    func requestPermission() -> Bool {
        requestPermissionCallCount += 1
        return true
    }

    func refreshPermission() -> Bool {
        refreshPermissionCallCount += 1
        return true
    }

    func submitRefresh(
        intent: DisplayRuntimeCatalogRefreshIntent,
        ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?
    ) async -> DisplayRuntimeCatalogRefreshResult {
        submitCalls.append(.init(intent: intent, ownerScope: ownerScope))
        return .reloadedSnapshot
    }

    func clearSnapshotForDeniedPermission(loadErrorMessage _: String?) async {}

    func cancelRefresh(ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?) async {
        cancelCalls.append(ownerScope)
    }

    func currentVisibleDisplays() -> [DisplayRuntimeVisibleDisplay] {
        []
    }
}

@MainActor
private final class SharingForwardingHarness: DisplayRuntimeSharingProviding, DisplayRuntimeSharingCommanding {
    let snapshot: DisplayRuntimeSharingSnapshot

    init(snapshot: DisplayRuntimeSharingSnapshot) {
        self.snapshot = snapshot
    }

    func makeSharingSnapshot() -> DisplayRuntimeSharingSnapshot {
        snapshot
    }

    func registerShareableDisplays(_: [DisplayRuntimeShareableDisplayRegistration]) {}
}
