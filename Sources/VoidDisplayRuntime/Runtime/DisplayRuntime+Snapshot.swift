import Foundation

@MainActor
extension DisplayRuntime {
    package func makeSnapshot() -> DisplayRuntimeSnapshot {
        let catalog = catalogProvider?.makeCatalogSnapshot() ?? .empty
        let capture = captureProvider?.makeCaptureSnapshot() ?? .empty
        let sharing = sharingProvider?.makeSharingSnapshot() ?? .empty
        let virtualDisplay = virtualDisplayProvider?.makeVirtualDisplaySnapshot() ?? .empty
        return DisplayRuntimeSnapshot(
            surfaces: DisplaySurfaceGraphBuilder.makeSurfaces(
                catalog: catalog,
                capture: capture,
                sharing: sharing,
                virtualDisplay: virtualDisplay
            ),
            catalog: catalog,
            capture: capture,
            sharing: sharing,
            virtualDisplay: virtualDisplay,
            transactions: .init(
                activeTransactions: Array(activeTransactionTracesByID.values),
                recentTransactions: recentTransactionTraces
            )
        )
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
