import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
enum ScreenCatalogSource: Sendable, Equatable {
    case capturePage
    case sharingPage
}

@MainActor
final class ScreenCatalogOrchestrator {
    private let catalogService: ScreenCaptureCatalogService
    private let capture: CaptureController
    private let sharing: SharingController
    private let virtualDisplay: VirtualDisplayController
    private weak var observability: ObservabilityCenter?
    private let captureRefreshOwner = ScreenCaptureCatalogService.RefreshOwner()
    private let sharingRefreshOwner = ScreenCaptureCatalogService.RefreshOwner()

    private var topologyRefreshTask: Task<Void, Never>?
    private var hasPendingTopologyChange = false

    init(
        catalogService: ScreenCaptureCatalogService,
        capture: CaptureController,
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController,
        observability: ObservabilityCenter? = nil
    ) {
        self.catalogService = catalogService
        self.capture = capture
        self.sharing = sharing
        self.virtualDisplay = virtualDisplay
        self.observability = observability
    }

    func handleAppear(source: ScreenCatalogSource) async {
        await refreshPermissionIfNeeded(source: source)
    }

    func handleDisappear(source: ScreenCatalogSource) async {
        await cancelRefresh(for: source)
    }

    func requestPermission(source: ScreenCatalogSource) async {
        await requestPermissionIfNeeded(source: source)
    }

    func refreshPermission(source: ScreenCatalogSource) async {
        await refreshPermissionIfNeeded(source: source)
    }

    func forceRefresh(source: ScreenCatalogSource) async {
        await forceRefreshIfNeeded(source: source)
    }

    func handleTopologyChanged() async {
        hasPendingTopologyChange = true
        if let topologyRefreshTask {
            await topologyRefreshTask.value
            return
        }
        let topologyRefreshTask = Task { @MainActor in
            defer { self.topologyRefreshTask = nil }
            await self.drainTopologyRefreshQueue()
        }
        self.topologyRefreshTask = topologyRefreshTask
        await topologyRefreshTask.value
    }

    func handleSharingServiceStateChanged(isRunning: Bool) async {
        if isRunning {
            await refreshSharingCatalogForRunningService()
        } else {
            await catalogService.cancelRefresh(owner: sharingRefreshOwner)
        }
    }

    func openScreenCapturePrivacySettings(openURL: (URL) -> Void) {
        catalogService.openScreenCapturePrivacySettings(openURL: openURL)
    }

    private func requestPermissionIfNeeded(source: ScreenCatalogSource) async {
        let granted = catalogService.requestPermission()
        guard granted else {
            let loadErrorMessage = source == .sharingPage
                ? String(localized: "Failed to load displays. Check permission and try again.")
                : nil
            await clearSnapshotForDeniedPermission(loadErrorMessage: loadErrorMessage)
            await recordPermissionEvent(granted: false, source: source)
            return
        }
        await recordPermissionEvent(granted: true, source: source)
        await refreshAfterPermissionGranted(source: source)
    }

    private func refreshPermissionIfNeeded(source: ScreenCatalogSource) async {
        let granted = catalogService.refreshPermission()
        guard granted else {
            await clearSnapshotForDeniedPermission()
            await recordPermissionEvent(granted: false, source: source)
            return
        }
        await recordPermissionEvent(granted: true, source: source)
        await refreshAfterPermissionGranted(source: source)
    }

    private func forceRefreshIfNeeded(source: ScreenCatalogSource) async {
        let granted = catalogService.refreshPermission()
        guard granted else {
            await clearSnapshotForDeniedPermission()
            return
        }

        switch source {
        case .capturePage:
            await refreshAndConverge(
                intent: .userForcedRefresh,
                owner: captureRefreshOwner
            )
        case .sharingPage:
            guard sharing.isWebServiceRunning else {
                await catalogService.cancelRefresh(owner: sharingRefreshOwner)
                return
            }
            await refreshAndConverge(
                intent: .userForcedRefresh,
                owner: sharingRefreshOwner
            )
        }
    }

    private func refreshAfterPermissionGranted(source: ScreenCatalogSource) async {
        switch source {
        case .capturePage:
            await refreshAndConverge(
                intent: .permissionChanged,
                owner: captureRefreshOwner
            )
        case .sharingPage:
            if sharing.isWebServiceRunning {
                await refreshSharingCatalogForRunningService()
            } else {
                await catalogService.cancelRefresh(owner: sharingRefreshOwner)
            }
        }
    }

    private func refreshSharingCatalogForRunningService() async {
        guard catalogService.refreshPermission() else {
            await clearSnapshotForDeniedPermission()
            return
        }
        guard sharing.isWebServiceRunning else {
            await catalogService.cancelRefresh(owner: sharingRefreshOwner)
            return
        }
        await refreshAndConverge(
            intent: .serviceBecameRunning,
            owner: sharingRefreshOwner
        )
    }

    private func cancelRefresh(for source: ScreenCatalogSource) async {
        switch source {
        case .capturePage:
            await catalogService.cancelRefresh(owner: captureRefreshOwner)
        case .sharingPage:
            await catalogService.cancelRefresh(owner: sharingRefreshOwner)
        }
    }

    private func clearSnapshotForDeniedPermission(loadErrorMessage: String? = nil) async {
        await catalogService.clearSnapshotForDeniedPermission(loadErrorMessage: loadErrorMessage)
        convergeToVisibleDisplays([])
        await observability?.record(
            ObservabilityEvent(
                severity: .warning,
                subsystem: .screenCatalog,
                operation: "Clear denied screen capture snapshot",
                message: "Cleared visible displays because screen capture permission is unavailable.",
                metadata: ["source": loadErrorMessage == nil ? "capture" : "sharing"],
                deduplicationKey: "screenCatalog.permission.denied"
            )
        )
    }

    private func drainTopologyRefreshQueue() async {
        while hasPendingTopologyChange {
            hasPendingTopologyChange = false
            await runTopologyRefreshSequence()
        }
    }

    private func runTopologyRefreshSequence() async {
        guard catalogService.refreshPermission() else {
            await clearSnapshotForDeniedPermission()
            return
        }

        let result = await catalogService.submitRefresh(intent: .topologyChanged)
        await observability?.refreshSnapshot(reason: .screenCatalogStateChanged)
        guard result != .failed else { return }
        convergeToVisibleDisplaysFromCurrentSnapshot()
    }

    private func refreshAndConverge(
        intent: ScreenCaptureCatalogRefreshIntent,
        owner: ScreenCaptureCatalogService.RefreshOwner? = nil
    ) async {
        let result = await catalogService.submitRefresh(intent: intent, owner: owner)
        await observability?.refreshSnapshot(reason: .screenCatalogStateChanged)
        guard result != .failed else { return }
        convergeToVisibleDisplaysFromCurrentSnapshot()
    }

    private func convergeToVisibleDisplaysFromCurrentSnapshot() {
        let visibleDisplays = catalogService.visibleDisplays(from: catalogService.store.displays ?? [])
        convergeToVisibleDisplays(visibleDisplays)
    }

    private func convergeToVisibleDisplays(_ visibleDisplays: [SCDisplay]) {
        if sharing.isWebServiceRunning {
            sharing.registerShareableDisplays(visibleDisplays) { [weak virtualDisplay] displayID in
                virtualDisplay?.virtualSerialForManagedDisplay(displayID)
            }
        }

        let visibleDisplayIDs = Set(visibleDisplays.map(\.displayID))
        for displayID in sharing.activeSharingDisplayIDs where !visibleDisplayIDs.contains(displayID) {
            sharing.stopSharing(displayID: displayID)
        }

        let monitoredDisplayIDs = Set(capture.screenCaptureSessions.map(\.displayID))
        for displayID in monitoredDisplayIDs where !visibleDisplayIDs.contains(displayID) {
            capture.removeMonitoringSessions(displayID: displayID)
        }
    }

    private func recordPermissionEvent(
        granted: Bool,
        source: ScreenCatalogSource
    ) async {
        await observability?.record(
            ObservabilityEvent(
                severity: granted ? .info : .warning,
                subsystem: .screenCatalog,
                operation: "Screen capture permission check",
                message: granted
                    ? "Screen capture permission available."
                    : "Screen capture permission unavailable.",
                metadata: ["source": source == .capturePage ? "capture" : "sharing"],
                deduplicationKey: "screenCatalog.permission.\(source == .capturePage ? "capture" : "sharing")"
            )
        )
    }
}
