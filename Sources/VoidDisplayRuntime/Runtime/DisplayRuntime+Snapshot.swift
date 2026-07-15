import Foundation

@MainActor
extension DisplayRuntime {
    package func makeSnapshot() -> DisplayRuntimeSnapshot {
        let catalog = catalogProvider?.makeCatalogSnapshot() ?? .empty
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
            latestCaptureIntentRevision: currentLatestCaptureIntentRevision()
        )
    }

    package func surfaceIdentityForDisplayID(
        _ displayID: DisplayRuntimeDisplayID
    ) -> DisplaySurfaceIdentity? {
        makeSnapshot().surfaces.first {
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
