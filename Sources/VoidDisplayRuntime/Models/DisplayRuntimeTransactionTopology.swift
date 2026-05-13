import Foundation

package nonisolated struct DisplayRuntimeTopologyStabilitySample: Codable, Equatable, Sendable {
    package let topologySignature: [DisplayRuntimeCatalogTopologyEntry]
    package let visibleDisplayIDs: [DisplayRuntimeDisplayID]
    package let managedVirtualDisplays: [DisplayRuntimeTopologyManagedVirtualDisplaySample]

    package init(
        topologySignature: [DisplayRuntimeCatalogTopologyEntry],
        visibleDisplayIDs: [DisplayRuntimeDisplayID],
        managedVirtualDisplays: [DisplayRuntimeTopologyManagedVirtualDisplaySample]
    ) {
        self.topologySignature = topologySignature.sorted { $0.displayID < $1.displayID }
        self.visibleDisplayIDs = visibleDisplayIDs.sorted()
        self.managedVirtualDisplays = managedVirtualDisplays.sorted {
            ($0.configID.uuidString, $0.displayID, $0.isLiveRuntime ? 1 : 0)
                < ($1.configID.uuidString, $1.displayID, $1.isLiveRuntime ? 1 : 0)
        }
    }

    package init(snapshot: DisplayRuntimeSnapshot) {
        self.init(
            topologySignature: snapshot.catalog.topologySignature,
            visibleDisplayIDs: snapshot.catalog.loadedDisplays.map(\.displayID),
            managedVirtualDisplays: snapshot.virtualDisplay.managedDisplays.map {
                .init(
                    configID: $0.configID,
                    displayID: $0.displayID,
                    isLiveRuntime: $0.isLiveRuntime
                )
            }
        )
    }
}

package nonisolated struct DisplayRuntimeTopologyManagedVirtualDisplaySample: Codable, Equatable, Sendable {
    package let configID: UUID
    package let displayID: DisplayRuntimeDisplayID
    package let isLiveRuntime: Bool

    package init(
        configID: UUID,
        displayID: DisplayRuntimeDisplayID,
        isLiveRuntime: Bool
    ) {
        self.configID = configID
        self.displayID = displayID
        self.isLiveRuntime = isLiveRuntime
    }
}

package nonisolated enum DisplayRuntimeTopologyStabilityStatus: String, Codable, Equatable, Sendable {
    case stable
    case unprovableDueToPermission
    case failed
    case timedOut
}

package nonisolated struct DisplayRuntimeTopologyStabilityResult: Codable, Equatable, Sendable {
    package let status: DisplayRuntimeTopologyStabilityStatus
    package let sampleCount: Int
    package let failureReason: String?
    package let lastSample: DisplayRuntimeTopologyStabilitySample?

    package init(
        status: DisplayRuntimeTopologyStabilityStatus,
        sampleCount: Int,
        failureReason: String?,
        lastSample: DisplayRuntimeTopologyStabilitySample?
    ) {
        self.status = status
        self.sampleCount = sampleCount
        self.failureReason = failureReason
        self.lastSample = lastSample
    }
}
