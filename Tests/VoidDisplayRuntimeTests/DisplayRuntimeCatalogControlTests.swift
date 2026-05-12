@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeCatalogControlTests {
    @Test func captureAppearRefreshesAndConvergesVisibleDisplays() async {
        let removedDisplayID = DisplayRuntimeDisplayID(1001)
        let keptDisplayID = DisplayRuntimeDisplayID(1002)
        let catalog = CatalogControlHarness(
            visibleDisplays: [.init(displayID: keptDisplayID, pixelWidth: 2560, pixelHeight: 1440)]
        )
        let capture = CaptureControlHarness(
            snapshot: makeCaptureSnapshot(displayIDs: [removedDisplayID, keptDisplayID])
        )
        let sharing = SharingControlHarness(
            snapshot: makeSharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [removedDisplayID, keptDisplayID])
        )
        let virtualDisplay = VirtualDisplayControlHarness(
            snapshot: makeVirtualDisplaySnapshot(displayID: keptDisplayID, serialNumber: 9002)
        )
        let runtime = makeRuntime(
            catalog: catalog,
            capture: capture,
            sharing: sharing,
            virtualDisplay: virtualDisplay
        )

        await runtime.handleCatalogAppear(source: .capturePage)

        #expect(catalog.submitCalls == [.init(intent: .permissionChanged, ownerScope: .capture)])
        #expect(sharing.registeredDisplays == [[
            .init(displayID: keptDisplayID, virtualSerialNumber: 9002)
        ]])
        #expect(sharing.stoppedDisplayIDs == [removedDisplayID])
        #expect(capture.removedDisplayIDs == [removedDisplayID])
    }

    @Test func sharingAppearWithStoppedServiceCancelsRefreshWithoutClearingSnapshot() async {
        let catalog = CatalogControlHarness(
            visibleDisplays: [.init(displayID: 2001, pixelWidth: 1920, pixelHeight: 1080)]
        )
        let sharing = SharingControlHarness(
            snapshot: makeSharingSnapshot(isWebServiceRunning: false, activeDisplayIDs: [])
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
        let catalog = CatalogControlHarness(
            submitRefreshResults: [.reusedSnapshot],
            visibleDisplays: [.init(displayID: displayID, pixelWidth: 2560, pixelHeight: 1440)]
        )
        let sharing = SharingControlHarness(
            snapshot: makeSharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [])
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
        let catalog = CatalogControlHarness(
            refreshPermissionResults: [false],
            visibleDisplays: [.init(displayID: removedDisplayID, pixelWidth: 1920, pixelHeight: 1080)]
        )
        let capture = CaptureControlHarness(snapshot: makeCaptureSnapshot(displayIDs: [removedDisplayID]))
        let sharing = SharingControlHarness(
            snapshot: makeSharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [removedDisplayID])
        )
        let observability = ObservabilityControlHarness()
        let runtime = makeRuntime(
            catalog: catalog,
            capture: capture,
            sharing: sharing,
            observability: observability
        )

        await runtime.refreshCatalogPermission(source: .capturePage)

        #expect(catalog.clearLoadErrorMessages == [nil])
        #expect(sharing.registeredDisplays == [[]])
        #expect(sharing.stoppedDisplayIDs == [removedDisplayID])
        #expect(capture.removedDisplayIDs == [removedDisplayID])
        #expect(observability.events.map(\.deduplicationKey).contains("screenCatalog.permission.denied"))
        #expect(observability.refreshReasons == [.screenCatalogStateChanged])
    }

    @Test func sharingPermissionRequestDeniedPassesLoadErrorMessage() async {
        let catalog = CatalogControlHarness()
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
        let catalog = CatalogControlHarness(
            visibleDisplays: [.init(displayID: firstDisplayID, pixelWidth: 1920, pixelHeight: 1080)]
        )
        catalog.shouldGateSubmitRefresh = true
        let sharing = SharingControlHarness(
            snapshot: makeSharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [])
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
        let catalog = CatalogControlHarness(
            submitRefreshResults: [.failed],
            visibleDisplays: [.init(displayID: 6001, pixelWidth: 1920, pixelHeight: 1080)]
        )
        let capture = CaptureControlHarness(snapshot: makeCaptureSnapshot(displayIDs: [6002]))
        let sharing = SharingControlHarness(
            snapshot: makeSharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [6002])
        )
        let runtime = makeRuntime(catalog: catalog, capture: capture, sharing: sharing)

        await runtime.forceRefreshCatalog(source: .capturePage)

        #expect(catalog.submitCalls == [.init(intent: .userForcedRefresh, ownerScope: .capture)])
        #expect(sharing.registeredDisplays.isEmpty)
        #expect(sharing.stoppedDisplayIDs.isEmpty)
        #expect(capture.removedDisplayIDs.isEmpty)
    }

    @Test func clearedRefreshResultConvergesWithEmptyVisibleDisplays() async {
        let staleDisplayID = DisplayRuntimeDisplayID(6501)
        let catalog = CatalogControlHarness(
            submitRefreshResults: [.clearedSnapshot],
            visibleDisplays: [.init(displayID: staleDisplayID, pixelWidth: 1920, pixelHeight: 1080)]
        )
        let capture = CaptureControlHarness(snapshot: makeCaptureSnapshot(displayIDs: [staleDisplayID]))
        let sharing = SharingControlHarness(
            snapshot: makeSharingSnapshot(isWebServiceRunning: true, activeDisplayIDs: [staleDisplayID])
        )
        let runtime = makeRuntime(catalog: catalog, capture: capture, sharing: sharing)

        await runtime.forceRefreshCatalog(source: .capturePage)

        #expect(sharing.registeredDisplays == [[]])
        #expect(sharing.stoppedDisplayIDs == [staleDisplayID])
        #expect(capture.removedDisplayIDs == [staleDisplayID])
    }

    @Test func sharingServiceStateChangeReadsCurrentSharingSnapshot() async {
        let catalog = CatalogControlHarness(
            visibleDisplays: [.init(displayID: 7001, pixelWidth: 1920, pixelHeight: 1080)]
        )
        let sharing = SharingControlHarness(
            snapshot: makeSharingSnapshot(isWebServiceRunning: false, activeDisplayIDs: [])
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
    catalog: CatalogControlHarness,
    capture: CaptureControlHarness = CaptureControlHarness(),
    sharing: SharingControlHarness = SharingControlHarness(),
    virtualDisplay: VirtualDisplayControlHarness = VirtualDisplayControlHarness(),
    observability: ObservabilityControlHarness = ObservabilityControlHarness()
) -> DisplayRuntime {
    DisplayRuntime(
        catalogProvider: catalog,
        captureProvider: capture,
        sharingProvider: sharing,
        virtualDisplayProvider: virtualDisplay,
        catalogCommander: catalog,
        sharingCommander: sharing,
        captureCommander: capture,
        observabilityRecorder: observability
    )
}

private struct CatalogSubmitCall: Equatable {
    let intent: DisplayRuntimeCatalogRefreshIntent
    let ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?
}

@MainActor
private final class CatalogControlHarness: DisplayRuntimeCatalogProviding, DisplayRuntimeCatalogCommanding {
    var snapshot: DisplayRuntimeCatalogSnapshot
    var requestPermissionResult = true
    var refreshPermissionResults: [Bool]
    var submitRefreshResults: [DisplayRuntimeCatalogRefreshResult]
    var visibleDisplays: [DisplayRuntimeVisibleDisplay]
    var shouldGateSubmitRefresh = false
    private var submitContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var submitCallWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var requestPermissionCallCount = 0
    private(set) var refreshPermissionCallCount = 0
    private(set) var submitCalls: [CatalogSubmitCall] = []
    private(set) var clearLoadErrorMessages: [String?] = []
    private(set) var cancelledOwnerScopes: [DisplayRuntimeCatalogRefreshOwnerScope?] = []

    init(
        snapshot: DisplayRuntimeCatalogSnapshot = .empty,
        refreshPermissionResults: [Bool] = [true],
        submitRefreshResults: [DisplayRuntimeCatalogRefreshResult] = [.reloadedSnapshot],
        visibleDisplays: [DisplayRuntimeVisibleDisplay] = []
    ) {
        self.snapshot = snapshot
        self.refreshPermissionResults = refreshPermissionResults
        self.submitRefreshResults = submitRefreshResults
        self.visibleDisplays = visibleDisplays
    }

    func makeCatalogSnapshot() -> DisplayRuntimeCatalogSnapshot {
        snapshot
    }

    func requestPermission() -> Bool {
        requestPermissionCallCount += 1
        return requestPermissionResult
    }

    func refreshPermission() -> Bool {
        refreshPermissionCallCount += 1
        guard !refreshPermissionResults.isEmpty else { return true }
        return refreshPermissionResults.removeFirst()
    }

    func submitRefresh(
        intent: DisplayRuntimeCatalogRefreshIntent,
        ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?
    ) async -> DisplayRuntimeCatalogRefreshResult {
        submitCalls.append(.init(intent: intent, ownerScope: ownerScope))
        resumeSubmitCallWaiters()
        let callIndex = submitCalls.count
        if shouldGateSubmitRefresh {
            await withCheckedContinuation { continuation in
                submitContinuations[callIndex] = continuation
            }
        }
        guard !submitRefreshResults.isEmpty else { return .reloadedSnapshot }
        return submitRefreshResults.removeFirst()
    }

    func clearSnapshotForDeniedPermission(loadErrorMessage: String?) async {
        clearLoadErrorMessages.append(loadErrorMessage)
    }

    func cancelRefresh(ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?) async {
        cancelledOwnerScopes.append(ownerScope)
    }

    func currentVisibleDisplays() -> [DisplayRuntimeVisibleDisplay] {
        visibleDisplays
    }

    func releaseSubmitRefresh(call: Int) {
        submitContinuations.removeValue(forKey: call)?.resume()
    }

    func waitForSubmitCalls(_ count: Int) async {
        guard submitCalls.count < count else { return }
        await withCheckedContinuation { continuation in
            submitCallWaiters[count, default: []].append(continuation)
        }
    }

    private func resumeSubmitCallWaiters() {
        let readyCounts = submitCallWaiters.keys.filter { submitCalls.count >= $0 }
        for count in readyCounts {
            let waiters = submitCallWaiters.removeValue(forKey: count) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}

@MainActor
private final class CaptureControlHarness: DisplayRuntimeCaptureProviding, DisplayRuntimeCaptureCommanding {
    var snapshot: DisplayRuntimeCaptureSnapshot
    private(set) var removedDisplayIDs: [DisplayRuntimeDisplayID] = []

    init(snapshot: DisplayRuntimeCaptureSnapshot = .empty) {
        self.snapshot = snapshot
    }

    func makeCaptureSnapshot() -> DisplayRuntimeCaptureSnapshot {
        snapshot
    }

    func removeMonitoringSessions(displayID: DisplayRuntimeDisplayID) {
        removedDisplayIDs.append(displayID)
    }
}

@MainActor
private final class SharingControlHarness: DisplayRuntimeSharingProviding, DisplayRuntimeSharingCommanding {
    var snapshot: DisplayRuntimeSharingSnapshot
    private(set) var registeredDisplays: [[DisplayRuntimeShareableDisplayRegistration]] = []
    private(set) var stoppedDisplayIDs: [DisplayRuntimeDisplayID] = []

    init(snapshot: DisplayRuntimeSharingSnapshot = .empty) {
        self.snapshot = snapshot
    }

    func makeSharingSnapshot() -> DisplayRuntimeSharingSnapshot {
        snapshot
    }

    func registerShareableDisplays(_ displays: [DisplayRuntimeShareableDisplayRegistration]) {
        registeredDisplays.append(displays)
    }

    func stopSharing(displayID: DisplayRuntimeDisplayID) {
        stoppedDisplayIDs.append(displayID)
    }

    func restoreSharing(displayID _: DisplayRuntimeDisplayID) async -> DisplayRuntimeSharingRestoreCommandResult {
        .restored
    }
}

@MainActor
private final class VirtualDisplayControlHarness: DisplayRuntimeVirtualDisplayProviding {
    var snapshot: DisplayRuntimeVirtualDisplaySnapshot

    init(snapshot: DisplayRuntimeVirtualDisplaySnapshot = .empty) {
        self.snapshot = snapshot
    }

    func makeVirtualDisplaySnapshot() -> DisplayRuntimeVirtualDisplaySnapshot {
        snapshot
    }
}

@MainActor
private final class ObservabilityControlHarness: DisplayRuntimeObservabilityRecording {
    private(set) var events: [DisplayRuntimeObservabilityEvent] = []
    private(set) var refreshReasons: [DisplayRuntimeObservabilityRefreshReason] = []

    func record(_ event: DisplayRuntimeObservabilityEvent) async {
        events.append(event)
    }

    func refreshSnapshot(reason: DisplayRuntimeObservabilityRefreshReason) async {
        refreshReasons.append(reason)
    }
}

private func makeCaptureSnapshot(displayIDs: [DisplayRuntimeDisplayID]) -> DisplayRuntimeCaptureSnapshot {
    DisplayRuntimeCaptureSnapshot(
        startingDisplayIDs: [],
        sessions: displayIDs.enumerated().map { index, displayID in
            DisplayRuntimeCaptureSession(
                id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index + 1))")!,
                displayID: displayID,
                isVirtualDisplay: false,
                capturesCursor: false,
                state: .active,
                metrics: .empty
            )
        }
    )
}

private func makeSharingSnapshot(
    isWebServiceRunning: Bool,
    activeDisplayIDs: [DisplayRuntimeDisplayID]
) -> DisplayRuntimeSharingSnapshot {
    DisplayRuntimeSharingSnapshot(
        activeSharingDisplayIDs: activeDisplayIDs,
        startingDisplayIDs: [],
        isSharing: !activeDisplayIDs.isEmpty,
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
}

private func makeVirtualDisplaySnapshot(
    displayID: DisplayRuntimeDisplayID,
    serialNumber: UInt32
) -> DisplayRuntimeVirtualDisplaySnapshot {
    DisplayRuntimeVirtualDisplaySnapshot(
        rebuildRequestCount: 0,
        rebuildingConfigIDs: [],
        runningConfigIDs: [],
        recentlyAppliedConfigIDs: [],
        rebuildFailureConfigIDs: [],
        configStoreHasLoadFailure: false,
        configStoreHasDiagnostics: false,
        managedDisplays: [
            .init(
                configID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                serialNumber: serialNumber,
                displayID: displayID,
                isLiveRuntime: true
            )
        ],
        configs: [],
        restoreFailureConfigIDs: []
    )
}
