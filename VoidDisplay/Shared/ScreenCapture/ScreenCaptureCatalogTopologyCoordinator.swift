import CoreGraphics
import ScreenCaptureKit

@MainActor
struct ScreenCaptureCatalogTopologyCoordinator {
    typealias ActiveDisplayIDsProvider = @MainActor () -> Set<CGDirectDisplayID>

    private let state: ScreenCaptureDisplayCatalogState
    private let activeDisplayIDsProvider: ActiveDisplayIDsProvider

    init(
        state: ScreenCaptureDisplayCatalogState,
        activeDisplayIDsProvider: @escaping ActiveDisplayIDsProvider
    ) {
        self.state = state
        self.activeDisplayIDsProvider = activeDisplayIDsProvider
    }

    func visibleDisplays(from displays: [SCDisplay]) -> [SCDisplay] {
        let activeDisplayIDs = activeDisplayIDsProvider()
        return displays.filter { activeDisplayIDs.contains($0.displayID) }
    }

    func needsRefresh() -> Bool {
        guard state.displays != nil else { return true }
        let currentSignature = currentActiveDisplayTopologySignature()
        guard let lastLoadedSignature = state.lastLoadedActiveDisplayTopologySignature else {
            return true
        }
        return currentSignature != lastLoadedSignature
    }

    func commitLoadedTopologySignature() {
        state.lastLoadedActiveDisplayTopologySignature = currentActiveDisplayTopologySignature()
    }

    func currentActiveDisplayTopologySignature() -> ScreenCaptureDisplayTopologySignature {
        ScreenCaptureDisplayTopologySignatureResolver.current(
            activeDisplayIDsProvider: activeDisplayIDsProvider
        )
    }
}
