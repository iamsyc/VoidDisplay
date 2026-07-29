import Foundation
import ScreenCaptureKit
import VoidDisplayCapture
import VoidDisplayFoundation
import VoidDisplayRuntime

@MainActor
package final class DisplayRuntimeCatalogAdapter: DisplayRuntimeCatalogProviding, DisplayRuntimeCatalogCommanding {
    private let service: ScreenCaptureCatalogService

    package init(service: ScreenCaptureCatalogService) {
        self.service = service
    }

    package func makeCatalogSnapshot() -> DisplayRuntimeCatalogSnapshot {
        DisplayRuntimeCatalogSnapshot(service.makeCatalogStateSnapshot())
    }

    package func requestPermission() -> Bool {
        service.requestPermission()
    }

    package func refreshPermission() -> Bool {
        service.refreshPermission()
    }

    package func submitRefresh(
        intent: DisplayRuntimeCatalogRefreshIntent
    ) async -> DisplayRuntimeCatalogRefreshOutcome {
        DisplayRuntimeCatalogRefreshOutcome(
            await service.submitRefresh(intent: ScreenCaptureCatalogRefreshIntent(intent))
        )
    }

    package func clearSnapshotForDeniedPermission(
        loadErrorMessage: String?
    ) async -> DisplayRuntimeCatalogRefreshOutcome {
        DisplayRuntimeCatalogRefreshOutcome(
            await service.clearSnapshotForDeniedPermission(loadErrorMessage: loadErrorMessage)
        )
    }
}

private extension DisplayRuntimeCatalogSnapshot {
    init(_ snapshot: ScreenCaptureCatalogStateSnapshot) {
        self.init(
            hasScreenCapturePermission: snapshot.hasScreenCapturePermission,
            lastPreflightPermission: snapshot.lastPreflightPermission,
            lastRequestPermission: snapshot.lastRequestPermission,
            isLoadingDisplays: snapshot.isLoadingDisplays,
            hasLoadError: snapshot.hasLoadError,
            lastLoadError: snapshot.lastLoadError.map {
                .init(
                    domain: $0.domain,
                    code: $0.code,
                    hasDescription: !$0.description.isEmpty,
                    hasFailureReason: $0.failureReason != nil,
                    hasRecoverySuggestion: $0.recoverySuggestion != nil
                )
            },
            loadedDisplays: snapshot.loadedDisplays.map {
                .init(
                    displayID: $0.displayID,
                    pixelWidth: $0.pixelWidth,
                    pixelHeight: $0.pixelHeight
                )
            },
            topologySignature: snapshot.topologySignature.map {
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
}

private extension DisplayRuntimeCatalogRefreshOutcome {
    init(_ settlement: ScreenCaptureCatalogRefreshSettlement) {
        self.init(
            settlementID: settlement.id,
            result: DisplayRuntimeCatalogRefreshResult(settlement.result),
            catalog: DisplayRuntimeCatalogSnapshot(settlement.catalog)
        )
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
        case .superseded:
            self = .superseded
        case .failed:
            self = .failed
        }
    }
}
