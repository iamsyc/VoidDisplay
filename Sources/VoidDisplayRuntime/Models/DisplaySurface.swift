import Foundation

package nonisolated enum DisplaySurfaceKind: String, Codable, Equatable, Sendable {
    case managedVirtualDisplay
    case physicalDisplay
}

package nonisolated struct DisplaySurfaceIdentity: Codable, Equatable, Hashable, Sendable {
    package let kind: DisplaySurfaceKind
    package let stableID: String

    package init(kind: DisplaySurfaceKind, stableID: String) {
        self.kind = kind
        self.stableID = stableID
    }

    package static func managedVirtualDisplay(configID: UUID) -> Self {
        Self(kind: .managedVirtualDisplay, stableID: configID.uuidString)
    }

    package static func physicalDisplay(displayID: DisplayRuntimeDisplayID) -> Self {
        Self(kind: .physicalDisplay, stableID: String(displayID))
    }
}

package nonisolated struct DisplaySurface: Codable, Equatable, Sendable {
    package let identity: DisplaySurfaceIdentity
    package let kind: DisplaySurfaceKind
    package let currentDisplayID: DisplayRuntimeDisplayID?
    package let isAuxiliary: Bool
    package let catalog: DisplayRuntimeCatalogSurfaceState?
    package let capture: DisplayRuntimeCaptureSurfaceState?
    package let sharing: DisplayRuntimeSharingSurfaceState?
    package let managedVirtualDisplay: DisplayRuntimeManagedVirtualDisplaySurfaceState?

    package init(
        identity: DisplaySurfaceIdentity,
        kind: DisplaySurfaceKind,
        currentDisplayID: DisplayRuntimeDisplayID?,
        isAuxiliary: Bool,
        catalog: DisplayRuntimeCatalogSurfaceState?,
        capture: DisplayRuntimeCaptureSurfaceState?,
        sharing: DisplayRuntimeSharingSurfaceState?,
        managedVirtualDisplay: DisplayRuntimeManagedVirtualDisplaySurfaceState?
    ) {
        self.identity = identity
        self.kind = kind
        self.currentDisplayID = currentDisplayID
        self.isAuxiliary = isAuxiliary
        self.catalog = catalog
        self.capture = capture
        self.sharing = sharing
        self.managedVirtualDisplay = managedVirtualDisplay
    }
}

package nonisolated struct DisplayRuntimeCatalogSurfaceState: Codable, Equatable, Sendable {
    package let displayID: DisplayRuntimeDisplayID
    package let isVisible: Bool
    package let isMain: Bool?
    package let pixelWidth: Int?
    package let pixelHeight: Int?
    package let refreshRateMilliHertz: Int?
    package let mirrorsDisplayID: DisplayRuntimeDisplayID?

    package init(
        displayID: DisplayRuntimeDisplayID,
        isVisible: Bool,
        isMain: Bool?,
        pixelWidth: Int?,
        pixelHeight: Int?,
        refreshRateMilliHertz: Int?,
        mirrorsDisplayID: DisplayRuntimeDisplayID?
    ) {
        self.displayID = displayID
        self.isVisible = isVisible
        self.isMain = isMain
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRateMilliHertz = refreshRateMilliHertz
        self.mirrorsDisplayID = mirrorsDisplayID
    }
}

package nonisolated struct DisplayRuntimeCaptureSurfaceState: Codable, Equatable, Sendable {
    package let displayID: DisplayRuntimeDisplayID
    package let isStarting: Bool
    package let sessionIDs: [UUID]
    package let capturesCursor: Bool
    package let receivedFrameCount: UInt64

    package init(
        displayID: DisplayRuntimeDisplayID,
        isStarting: Bool,
        sessionIDs: [UUID],
        capturesCursor: Bool,
        receivedFrameCount: UInt64
    ) {
        self.displayID = displayID
        self.isStarting = isStarting
        self.sessionIDs = sessionIDs.sorted { $0.uuidString < $1.uuidString }
        self.capturesCursor = capturesCursor
        self.receivedFrameCount = receivedFrameCount
    }
}

package nonisolated struct DisplayRuntimeSharingSurfaceState: Codable, Equatable, Sendable {
    package let displayID: DisplayRuntimeDisplayID
    package let isStarting: Bool
    package let isActive: Bool
    package let viewerCount: Int
    package let hasRoute: Bool

    package init(
        displayID: DisplayRuntimeDisplayID,
        isStarting: Bool,
        isActive: Bool,
        viewerCount: Int,
        hasRoute: Bool
    ) {
        self.displayID = displayID
        self.isStarting = isStarting
        self.isActive = isActive
        self.viewerCount = viewerCount
        self.hasRoute = hasRoute
    }
}

package nonisolated struct DisplayRuntimeManagedVirtualDisplaySurfaceState: Codable, Equatable, Sendable {
    package let configID: UUID
    package let serialNumber: UInt32?
    package let desiredEnabled: Bool?
    package let isRunning: Bool
    package let isLiveRuntime: Bool
    package let hasRestoreFailure: Bool
    package let modeCount: Int?
    package let maximumPixelWidth: Int?
    package let maximumPixelHeight: Int?

    package init(
        configID: UUID,
        serialNumber: UInt32?,
        desiredEnabled: Bool?,
        isRunning: Bool,
        isLiveRuntime: Bool,
        hasRestoreFailure: Bool,
        modeCount: Int?,
        maximumPixelWidth: Int?,
        maximumPixelHeight: Int?
    ) {
        self.configID = configID
        self.serialNumber = serialNumber
        self.desiredEnabled = desiredEnabled
        self.isRunning = isRunning
        self.isLiveRuntime = isLiveRuntime
        self.hasRestoreFailure = hasRestoreFailure
        self.modeCount = modeCount
        self.maximumPixelWidth = maximumPixelWidth
        self.maximumPixelHeight = maximumPixelHeight
    }
}
