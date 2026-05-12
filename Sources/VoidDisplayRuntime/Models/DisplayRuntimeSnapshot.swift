import Foundation

package nonisolated struct DisplayRuntimeSnapshot: Codable, Equatable, Sendable {
    package let schemaVersion: Int
    package let surfaces: [DisplaySurface]
    package let catalog: DisplayRuntimeCatalogSnapshot
    package let capture: DisplayRuntimeCaptureSnapshot
    package let sharing: DisplayRuntimeSharingSnapshot
    package let virtualDisplay: DisplayRuntimeVirtualDisplaySnapshot

    package init(
        schemaVersion: Int = 1,
        surfaces: [DisplaySurface],
        catalog: DisplayRuntimeCatalogSnapshot,
        capture: DisplayRuntimeCaptureSnapshot,
        sharing: DisplayRuntimeSharingSnapshot,
        virtualDisplay: DisplayRuntimeVirtualDisplaySnapshot
    ) {
        self.schemaVersion = schemaVersion
        self.surfaces = surfaces.sorted {
            ($0.kind.rawValue, $0.identity.stableID) < ($1.kind.rawValue, $1.identity.stableID)
        }
        self.catalog = catalog
        self.capture = capture
        self.sharing = sharing
        self.virtualDisplay = virtualDisplay
    }

    package static let empty = Self(
        surfaces: [],
        catalog: .empty,
        capture: .empty,
        sharing: .empty,
        virtualDisplay: .empty
    )
}
