import AppKit
import CoreGraphics
import Foundation
import Observation
import ScreenCaptureKit

@MainActor
@Observable
final class DisplayTopologyChangeCoordinator {
    enum Source: Sendable, Equatable {
        case captureView
        case sharingView
    }

    private let capture: CaptureController
    private let sharing: SharingController
    private let virtualDisplay: VirtualDisplayController
    private let catalogService: ScreenCaptureCatalogService
    private let refreshOwner = ScreenCaptureCatalogService.RefreshOwner()
    private var inFlightTask: Task<Void, Never>?
    private var hasPendingTopologyChange = false

    init(
        capture: CaptureController,
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController,
        catalogService: ScreenCaptureCatalogService
    ) {
        self.capture = capture
        self.sharing = sharing
        self.virtualDisplay = virtualDisplay
        self.catalogService = catalogService
    }

    func handleTopologyChange(source: Source) {
        _ = source
        hasPendingTopologyChange = true
        guard inFlightTask == nil else { return }
        inFlightTask = Task { @MainActor [weak self] in
            defer { self?.inFlightTask = nil }
            await self?.drainTopologyRefreshQueue()
        }
    }

    private func drainTopologyRefreshQueue() async {
        while hasPendingTopologyChange {
            hasPendingTopologyChange = false
            await runTopologyRefreshSequence()
        }
    }

    private func runTopologyRefreshSequence() async {
        guard catalogService.refreshPermission() else {
            await catalogService.clearSnapshotForDeniedPermission()
            convergeToVisibleDisplays([])
            return
        }

        let result = await catalogService.submitRefresh(intent: .topologyChanged, owner: refreshOwner)
        guard result != .failed else { return }

        let visibleDisplays = catalogService
            .visibleDisplays(from: catalogService.store.displays ?? [])
        convergeToVisibleDisplays(visibleDisplays)
    }

    private func convergeToVisibleDisplays(_ visibleDisplays: [SCDisplay]) {
        sharing.registerShareableDisplays(visibleDisplays) { [weak virtualDisplay] displayID in
            virtualDisplay?.virtualSerialForManagedDisplay(displayID)
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
}
