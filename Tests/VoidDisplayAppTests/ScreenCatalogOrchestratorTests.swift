@testable import VoidDisplayApp
@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct ScreenCatalogOrchestratorTests {
    @Test func publicCatalogActionsForwardToRuntime() async {
        await assertForwarding(
            action: { await $0.handleAppear(source: .capturePage) },
            expectedRefreshPermissionCalls: 1,
            expectedSubmitCalls: [.init(intent: .permissionChanged, ownerScope: .capture)]
        )
        await assertForwarding(
            action: { await $0.handleDisappear(source: .sharingPage) },
            expectedCancelCalls: [.sharing]
        )
        await assertForwarding(
            action: { await $0.requestPermission(source: .capturePage) },
            expectedRequestPermissionCalls: 1,
            expectedSubmitCalls: [.init(intent: .permissionChanged, ownerScope: .capture)]
        )
        await assertForwarding(
            action: { await $0.refreshPermission(source: .capturePage) },
            expectedRefreshPermissionCalls: 1,
            expectedSubmitCalls: [.init(intent: .permissionChanged, ownerScope: .capture)]
        )
        await assertForwarding(
            action: { await $0.forceRefresh(source: .capturePage) },
            expectedRefreshPermissionCalls: 1,
            expectedSubmitCalls: [.init(intent: .userForcedRefresh, ownerScope: .capture)]
        )
        await assertForwarding(
            action: { await $0.handleTopologyChanged() },
            expectedRefreshPermissionCalls: 1,
            expectedSubmitCalls: [.init(intent: .topologyChanged, ownerScope: nil)]
        )
        await assertForwarding(
            action: { await $0.handleSharingServiceStateChanged(isRunning: true) },
            expectedRefreshPermissionCalls: 1,
            expectedSubmitCalls: [.init(intent: .serviceBecameRunning, ownerScope: .sharing)]
        )
    }

    @Test func privacySettingsOpeningStaysInThinAdapter() {
        let expectedURL = URL(string: "x-voiddisplay-test://privacy")!
        var openedURL: URL?
        let runtime = DisplayRuntime()
        let sut = ScreenCatalogOrchestrator(
            runtime: runtime,
            openScreenCapturePrivacySettings: { openURL in
                openURL(expectedURL)
            }
        )

        sut.openScreenCapturePrivacySettings { url in
            openedURL = url
        }

        #expect(openedURL == expectedURL)
    }

    private func assertForwarding(
        action: (ScreenCatalogOrchestrator) async -> Void,
        expectedRequestPermissionCalls: Int = 0,
        expectedRefreshPermissionCalls: Int = 0,
        expectedSubmitCalls: [CatalogSubmitCall] = [],
        expectedCancelCalls: [DisplayRuntimeCatalogRefreshOwnerScope?] = []
    ) async {
        let catalog = CatalogForwardingHarness()
        let sharing = SharingForwardingHarness(
            snapshot: DisplayRuntimeSharingSnapshot(
                activeSharingDisplayIDs: [],
                startingDisplayIDs: [],
                isSharing: false,
                isWebServiceRunning: true,
                preferredPort: 8081,
                sharingClientCount: 0,
                sharingClientCounts: [],
                lifecycle: .init(
                    phase: .running,
                    requestedPort: 8081,
                    boundPort: 8081,
                    failureReason: nil,
                    hasFailureMessage: false
                ),
                routes: []
            )
        )
        let runtime = DisplayRuntime(
            catalogProvider: catalog,
            sharingProvider: sharing,
            catalogCommander: catalog,
            sharingCommander: sharing
        )
        let sut = ScreenCatalogOrchestrator(
            runtime: runtime,
            openScreenCapturePrivacySettings: { _ in }
        )

        await action(sut)

        #expect(catalog.requestPermissionCallCount == expectedRequestPermissionCalls)
        #expect(catalog.refreshPermissionCallCount == expectedRefreshPermissionCalls)
        #expect(catalog.submitCalls == expectedSubmitCalls)
        #expect(catalog.cancelCalls == expectedCancelCalls)
    }
}

private struct CatalogSubmitCall: Equatable {
    let intent: DisplayRuntimeCatalogRefreshIntent
    let ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?
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

    func stopSharing(displayID _: DisplayRuntimeDisplayID) {}
}
