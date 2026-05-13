import Foundation
import ScreenCaptureKit
import VoidDisplayCapture
import VoidDisplayFoundation
import VoidDisplayRuntime

@MainActor
package final class DisplayRuntimeCatalogAdapter: DisplayRuntimeCatalogProviding, DisplayRuntimeCatalogCommanding {
    private let service: ScreenCaptureCatalogService
    private let captureRefreshOwner = ScreenCaptureCatalogService.RefreshOwner()
    private let sharingRefreshOwner = ScreenCaptureCatalogService.RefreshOwner()

    package init(service: ScreenCaptureCatalogService) {
        self.service = service
    }

    package func makeCatalogSnapshot() -> DisplayRuntimeCatalogSnapshot {
        let store = service.store
        return DisplayRuntimeCatalogSnapshot(
            hasScreenCapturePermission: store.hasScreenCapturePermission,
            lastPreflightPermission: store.lastPreflightPermission,
            lastRequestPermission: store.lastRequestPermission,
            isLoadingDisplays: store.isLoadingDisplays,
            hasLoadError: store.loadErrorMessage != nil || store.lastLoadError != nil,
            lastLoadError: store.lastLoadError.map {
                .init(
                    domain: $0.domain,
                    code: $0.code,
                    hasDescription: !$0.description.isEmpty,
                    hasFailureReason: $0.failureReason != nil,
                    hasRecoverySuggestion: $0.recoverySuggestion != nil
                )
            },
            loadedDisplays: (store.displays ?? []).map {
                .init(
                    displayID: $0.displayID,
                    pixelWidth: $0.width,
                    pixelHeight: $0.height
                )
            },
            topologySignature: (store.lastLoadedActiveDisplayTopologySignature ?? []).map {
                .init(
                    displayID: $0.displayID,
                    isMain: $0.isMain,
                    pixelWidth: $0.pixelWidth,
                    pixelHeight: $0.pixelHeight,
                    refreshRateMilliHertz: $0.refreshRateMilliHertz,
                    mirrorsDisplayID: $0.mirrorsDisplayID
                )
            }
        )
    }

    package func requestPermission() -> Bool {
        service.requestPermission()
    }

    package func refreshPermission() -> Bool {
        service.refreshPermission()
    }

    package func submitRefresh(
        intent: DisplayRuntimeCatalogRefreshIntent,
        ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?
    ) async -> DisplayRuntimeCatalogRefreshResult {
        let result = await service.submitRefresh(
            intent: ScreenCaptureCatalogRefreshIntent(intent),
            owner: owner(for: ownerScope)
        )
        return DisplayRuntimeCatalogRefreshResult(result)
    }

    package func clearSnapshotForDeniedPermission(loadErrorMessage: String?) async {
        await service.clearSnapshotForDeniedPermission(loadErrorMessage: loadErrorMessage)
    }

    package func cancelRefresh(ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?) async {
        await service.cancelRefresh(owner: owner(for: ownerScope))
    }

    package func currentVisibleDisplays() -> [DisplayRuntimeVisibleDisplay] {
        return service.visibleDisplays(from: service.store.displays ?? []).map {
            DisplayRuntimeVisibleDisplay(
                displayID: $0.displayID,
                pixelWidth: $0.width,
                pixelHeight: $0.height
            )
        }
    }

    private func owner(
        for scope: DisplayRuntimeCatalogRefreshOwnerScope?
    ) -> ScreenCaptureCatalogService.RefreshOwner? {
        switch scope {
        case .capture:
            captureRefreshOwner
        case .sharing:
            sharingRefreshOwner
        case nil:
            nil
        }
    }
}

private extension ScreenCaptureCatalogRefreshIntent {
    init(_ intent: DisplayRuntimeCatalogRefreshIntent) {
        switch intent {
        case .permissionChanged:
            self = .permissionChanged
        case .topologyChanged:
            self = .topologyChanged
        case .serviceBecameRunning:
            self = .serviceBecameRunning
        case .userForcedRefresh:
            self = .userForcedRefresh
        }
    }
}

private extension DisplayRuntimeCatalogRefreshResult {
    init(_ result: ScreenCaptureCatalogRefreshResult) {
        switch result {
        case .reloadedSnapshot:
            self = .reloadedSnapshot
        case .reusedSnapshot:
            self = .reusedSnapshot
        case .clearedSnapshot:
            self = .clearedSnapshot
        case .failed:
            self = .failed
        }
    }
}
