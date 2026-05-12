import Foundation

package nonisolated struct DisplayRuntimeVirtualDisplaySnapshot: Codable, Equatable, Sendable {
    package let rebuildRequestCount: Int
    package let rebuildingConfigIDs: [UUID]
    package let runningConfigIDs: [UUID]
    package let recentlyAppliedConfigIDs: [UUID]
    package let rebuildFailureConfigIDs: [UUID]
    package let configStoreHasLoadFailure: Bool
    package let configStoreHasDiagnostics: Bool
    package let managedDisplays: [DisplayRuntimeManagedVirtualDisplay]
    package let configs: [DisplayRuntimeVirtualDisplayConfig]
    package let restoreFailureConfigIDs: [UUID]

    package init(
        rebuildRequestCount: Int,
        rebuildingConfigIDs: [UUID],
        runningConfigIDs: [UUID],
        recentlyAppliedConfigIDs: [UUID],
        rebuildFailureConfigIDs: [UUID],
        configStoreHasLoadFailure: Bool,
        configStoreHasDiagnostics: Bool,
        managedDisplays: [DisplayRuntimeManagedVirtualDisplay],
        configs: [DisplayRuntimeVirtualDisplayConfig],
        restoreFailureConfigIDs: [UUID]
    ) {
        self.rebuildRequestCount = rebuildRequestCount
        self.rebuildingConfigIDs = rebuildingConfigIDs.sortedByUUIDString()
        self.runningConfigIDs = runningConfigIDs.sortedByUUIDString()
        self.recentlyAppliedConfigIDs = recentlyAppliedConfigIDs.sortedByUUIDString()
        self.rebuildFailureConfigIDs = rebuildFailureConfigIDs.sortedByUUIDString()
        self.configStoreHasLoadFailure = configStoreHasLoadFailure
        self.configStoreHasDiagnostics = configStoreHasDiagnostics
        self.managedDisplays = managedDisplays.sorted { $0.configID.uuidString < $1.configID.uuidString }
        self.configs = configs.sorted { $0.id.uuidString < $1.id.uuidString }
        self.restoreFailureConfigIDs = restoreFailureConfigIDs.sortedByUUIDString()
    }

    package static let empty = Self(
        rebuildRequestCount: 0,
        rebuildingConfigIDs: [],
        runningConfigIDs: [],
        recentlyAppliedConfigIDs: [],
        rebuildFailureConfigIDs: [],
        configStoreHasLoadFailure: false,
        configStoreHasDiagnostics: false,
        managedDisplays: [],
        configs: [],
        restoreFailureConfigIDs: []
    )
}

package nonisolated struct DisplayRuntimeManagedVirtualDisplay: Codable, Equatable, Sendable {
    package let configID: UUID
    package let serialNumber: UInt32
    package let displayID: DisplayRuntimeDisplayID
    package let isLiveRuntime: Bool

    package init(
        configID: UUID,
        serialNumber: UInt32,
        displayID: DisplayRuntimeDisplayID,
        isLiveRuntime: Bool
    ) {
        self.configID = configID
        self.serialNumber = serialNumber
        self.displayID = displayID
        self.isLiveRuntime = isLiveRuntime
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayConfig: Codable, Equatable, Sendable {
    package let id: UUID
    package let serialNumber: UInt32
    package let desiredEnabled: Bool
    package let physicalWidthMillimeters: Int
    package let physicalHeightMillimeters: Int
    package let modes: [DisplayRuntimeVirtualDisplayMode]

    package init(
        id: UUID,
        serialNumber: UInt32,
        desiredEnabled: Bool,
        physicalWidthMillimeters: Int,
        physicalHeightMillimeters: Int,
        modes: [DisplayRuntimeVirtualDisplayMode]
    ) {
        self.id = id
        self.serialNumber = serialNumber
        self.desiredEnabled = desiredEnabled
        self.physicalWidthMillimeters = physicalWidthMillimeters
        self.physicalHeightMillimeters = physicalHeightMillimeters
        self.modes = modes.sorted {
            ($0.width, $0.height, $0.refreshRate, $0.enableHiDPI ? 1 : 0)
                < ($1.width, $1.height, $1.refreshRate, $1.enableHiDPI ? 1 : 0)
        }
    }

    package var maximumPixelDimensions: (width: UInt32, height: UInt32) {
        guard let maxMode = modes.max(by: { pixelArea($0) < pixelArea($1) }) else {
            return (0, 0)
        }
        let scale: Int = modes.contains(where: \.enableHiDPI) ? 2 : 1
        let (width, widthOverflow) = maxMode.width.multipliedReportingOverflow(by: scale)
        let (height, heightOverflow) = maxMode.height.multipliedReportingOverflow(by: scale)
        guard !widthOverflow, !heightOverflow else { return (UInt32.max, UInt32.max) }
        return (UInt32(clamping: width), UInt32(clamping: height))
    }

    private func pixelArea(_ mode: DisplayRuntimeVirtualDisplayMode) -> Int {
        let (area, overflow) = mode.width.multipliedReportingOverflow(by: mode.height)
        guard !overflow else { return Int.max }
        return max(0, area)
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayMode: Codable, Equatable, Sendable {
    package let width: Int
    package let height: Int
    package let refreshRate: Double
    package let enableHiDPI: Bool

    package init(width: Int, height: Int, refreshRate: Double, enableHiDPI: Bool) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.enableHiDPI = enableHiDPI
    }
}

private nonisolated extension Array where Element == UUID {
    func sortedByUUIDString() -> [UUID] {
        sorted { $0.uuidString < $1.uuidString }
    }
}
