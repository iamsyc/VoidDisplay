import Foundation
import CoreGraphics
import ScreenCaptureKit

@MainActor
package struct ScreenCaptureCatalogTopologyCoordinator {
    package typealias ActiveDisplayIDsProvider = @MainActor () -> Set<CGDirectDisplayID>

    private let state: ScreenCaptureDisplayCatalogState
    private let activeDisplayIDsProvider: ActiveDisplayIDsProvider

    package init(
        state: ScreenCaptureDisplayCatalogState,
        activeDisplayIDsProvider: @escaping ActiveDisplayIDsProvider
    ) {
        self.state = state
        self.activeDisplayIDsProvider = activeDisplayIDsProvider
    }

    package func visibleDisplays(from displays: [SCDisplay]) -> [SCDisplay] {
        let activeDisplayIDs = activeDisplayIDsProvider()
        return displays.filter { activeDisplayIDs.contains($0.displayID) }
    }

    package func needsRefresh() -> Bool {
        guard state.displays != nil else { return true }
        let currentSignature = currentActiveDisplayTopologySignature()
        guard let lastLoadedSignature = state.lastLoadedActiveDisplayTopologySignature else {
            return true
        }
        return currentSignature != lastLoadedSignature
    }

    package func commitLoadedTopologySignature() {
        state.lastLoadedActiveDisplayTopologySignature = currentActiveDisplayTopologySignature()
    }

    package func currentActiveDisplayTopologySignature() -> ScreenCaptureDisplayTopologySignature {
        ScreenCaptureDisplayTopologySignatureResolver.current(
            activeDisplayIDsProvider: activeDisplayIDsProvider
        )
    }
}
