import VoidDisplayObservability
import VoidDisplayFoundation
import Foundation
package struct ScreenCatalogSnapshotProvider: ObservabilitySnapshotProvider, @unchecked Sendable {
    package nonisolated struct Snapshot: Codable, Equatable, Sendable {
         package nonisolated struct LoadError: Codable, Equatable, Sendable {
            let domain: String
            let code: Int
            let description: String
            let failureReason: String?
            let recoverySuggestion: String?
        }
         package nonisolated struct TopologyEntry: Codable, Equatable, Sendable {
            let displayID: UInt32
            let isMain: Bool
            let pixelWidth: Int
            let pixelHeight: Int
            let refreshRateMilliHertz: Int?
            let mirrorsDisplayID: UInt32?
        }

        let hasScreenCapturePermission: Bool?
        let lastPreflightPermission: Bool?
        let lastRequestPermission: Bool?
        let isLoadingDisplays: Bool
        let loadErrorMessage: String?
        let lastLoadError: LoadError?
        let loadedDisplayIDs: [UInt32]
        let topologySignature: [TopologyEntry]
    }

    package let key = "screenCatalog"
    private weak var store: ScreenCaptureCatalogStore?

    package init(store: ScreenCaptureCatalogStore) {
        self.store = store
    }

    @MainActor
    package func makeSnapshot() -> Snapshot {
        guard let store else {
            return Snapshot(
                hasScreenCapturePermission: nil,
                lastPreflightPermission: nil,
                lastRequestPermission: nil,
                isLoadingDisplays: false,
                loadErrorMessage: nil,
                lastLoadError: nil,
                loadedDisplayIDs: [],
                topologySignature: []
            )
        }
        return Snapshot(
            hasScreenCapturePermission: store.hasScreenCapturePermission,
            lastPreflightPermission: store.lastPreflightPermission,
            lastRequestPermission: store.lastRequestPermission,
            isLoadingDisplays: store.isLoadingDisplays,
            loadErrorMessage: store.loadErrorMessage,
            lastLoadError: store.lastLoadError.map {
                .init(
                    domain: $0.domain,
                    code: $0.code,
                    description: $0.description,
                    failureReason: $0.failureReason,
                    recoverySuggestion: $0.recoverySuggestion
                )
            },
            loadedDisplayIDs: (store.displays ?? []).map(\.displayID).sorted(),
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
}
