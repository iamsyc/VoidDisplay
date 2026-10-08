import Foundation

@MainActor
extension DisplayRuntime {
    package func makeSnapshot() -> DisplayRuntimeSnapshot {
        let catalog = currentCatalogSnapshot()
        return makeSnapshot(catalog: catalog)
    }

    package func currentCatalogSnapshot() -> DisplayRuntimeCatalogSnapshot {
        catalogProvider?.makeCatalogSnapshot() ?? .empty
    }

    package func managedDisplayID(for configID: UUID) -> DisplayRuntimeDisplayID? {
        currentVirtualDisplaySnapshot().managedDisplays.first { $0.configID == configID }?.displayID
    }

    func makeSnapshot(catalog: DisplayRuntimeCatalogSnapshot) -> DisplayRuntimeSnapshot {
        let capture = captureProvider?.makeCaptureSnapshot() ?? .empty
        let sharing = sharingProvider?.makeSharingSnapshot() ?? .empty
        let virtualDisplay = virtualDisplayProvider?.makeVirtualDisplaySnapshot() ?? .empty
        let surfaces = DisplaySurfaceGraphBuilder.makeSurfaces(
            catalog: catalog,
            capture: capture,
            sharing: sharing,
            virtualDisplay: virtualDisplay
        )
        let consumerLeases = currentConsumerLeaseSnapshot().map(DisplayRuntimeConsumerLeaseSnapshot.init)
        let aggregatedDemands = currentAggregatedDemandSnapshot(surfaces: surfaces)
        let effectiveCaptureIntents = currentEffectiveCaptureIntentSnapshot()
        return DisplayRuntimeSnapshot(
            surfaces: surfaces,
            catalog: catalog,
            capture: capture,
            sharing: sharing,
            virtualDisplay: virtualDisplay,
            transactions: .init(
                activeTransactions: Array(activeTransactionTracesByID.values),
                recentTransactions: recentTransactionTraces
            ),
            consumerLeases: consumerLeases,
            aggregatedDemands: aggregatedDemands,
            effectiveCaptureIntents: effectiveCaptureIntents,
            surfaceEpochs: currentSurfaceEpochSnapshot(),
            latestCaptureIntentRevision: currentLatestCaptureIntentRevision(),
            latestFailure: latestFailure
        )
    }

    func currentSurfaceSnapshot() -> [DisplaySurface] {
        DisplaySurfaceGraphBuilder.makeSurfaces(
            catalog: currentCatalogSnapshot(),
            capture: currentCaptureSnapshot(),
            sharing: currentSharingSnapshot(),
            virtualDisplay: currentVirtualDisplaySnapshot()
        )
    }

    package func surfaceIdentityForDisplayID(
        _ displayID: DisplayRuntimeDisplayID
    ) -> DisplaySurfaceIdentity? {
        let catalog = currentCatalogSnapshot()
        let virtualDisplay = currentVirtualDisplaySnapshot()
        let catalogSurfaces = DisplaySurfaceGraphBuilder.makeSurfaces(
            catalog: catalog,
            capture: .empty,
            sharing: .empty,
            virtualDisplay: virtualDisplay
        )
        if let surface = catalogSurfaces.first(where: { $0.currentDisplayID == displayID }) {
            return surface.identity
        }
        return DisplaySurfaceGraphBuilder.makeSurfaces(
            catalog: catalog,
            capture: currentCaptureSnapshot(),
            sharing: currentSharingSnapshot(),
            virtualDisplay: virtualDisplay
        ).first {
            $0.currentDisplayID == displayID
        }?.identity
    }

    func currentCaptureSnapshot() -> DisplayRuntimeCaptureSnapshot {
        captureProvider?.makeCaptureSnapshot() ?? .empty
    }

    func currentSharingSnapshot() -> DisplayRuntimeSharingSnapshot {
        sharingProvider?.makeSharingSnapshot() ?? .empty
    }

    func currentVirtualDisplaySnapshot() -> DisplayRuntimeVirtualDisplaySnapshot {
        virtualDisplayProvider?.makeVirtualDisplaySnapshot() ?? .empty
    }
}
