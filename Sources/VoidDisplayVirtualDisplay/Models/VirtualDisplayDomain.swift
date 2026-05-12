import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import CoreGraphics
package struct VirtualDisplayConfigStorePresentation: Equatable {
    package var hasLoadFailure = false
    package var loadErrorMessage: String?
    package var diagnosticsSummary: String?

    package init(
        hasLoadFailure: Bool = false,
        loadErrorMessage: String? = nil,
        diagnosticsSummary: String? = nil
    ) {
        self.hasLoadFailure = hasLoadFailure
        self.loadErrorMessage = loadErrorMessage
        self.diagnosticsSummary = diagnosticsSummary
    }
}
package enum VirtualDisplayReorderDirection {
    case up
    case down
}
package enum VirtualDisplayTopologyRecoveryMode {
    case fast
    case aggressive
}

package extension VirtualDisplayTopologyRecoveryMode {
    var logDescription: String {
        switch self {
        case .fast: return "fast"
        case .aggressive: return "aggressive"
        }
    }
}
package struct VirtualDisplayAdaptiveCooldownResult {
    package let waitedSeconds: TimeInterval
    package let completedEarly: Bool
}
package enum VirtualDisplayOperationError: LocalizedError {
    case duplicateSerialNumber(UInt32)
    case invalidConfiguration(String)
    case creationFailed
    case persistenceRecoveryFailed(String)
    case configNotFound
    case teardownTimedOut
    case topologyRepairFailed
    case topologyUnstableAfterEnable

    package var errorDescription: String? {
        switch self {
        case .duplicateSerialNumber(let num):
            return String(localized: "Serial number \(num) is already in use.")
        case .invalidConfiguration(let reason):
            return String(localized: "Invalid configuration: \(reason)")
        case .creationFailed:
            return String(localized: "Virtual display creation failed.")
        case .persistenceRecoveryFailed(let message):
            return message
        case .configNotFound:
            return String(localized: "Display configuration not found.")
        case .teardownTimedOut:
            return String(localized: "Display teardown timed out. Wait a moment and try rebuilding again.")
        case .topologyRepairFailed:
            return String(localized: "Display topology repair failed. Open System Display Settings and recheck arrangement.")
        case .topologyUnstableAfterEnable:
            return String(localized: "Display topology did not stabilize after enabling. Please try again.")
        }
    }
}
package enum VirtualDisplayEditRebuildPersistenceError: Error, Equatable {
    case editRequestStale
}
package enum VirtualDisplayTimingPolicy {
    package static let rollbackOfflineWaitTimeout: TimeInterval = 1.2
    package static let rebuildTerminationTimeout: TimeInterval = 2.0
    package static let rebuildOfflineTimeout: TimeInterval = 4.0
    package static let rebuildFinalOfflineConfirmationTimeout: TimeInterval = 0.8
    package static let rebuildFleetCreationCooldown: TimeInterval = 0.6
    package static let rebuildFleetCreationCooldownFastTeardown: TimeInterval = 0.15
    package static let deferredTopologyRecheckMinimumDelay: TimeInterval = 0.03
    package static let deferredTopologyRecheckMultiplier: TimeInterval = 1.5
    package static let aggressiveEnableUnsettledTeardownCooldown: TimeInterval = 0.35
    package static let adaptiveCooldownPollIntervalFloor: TimeInterval = 0.01
    package static let adaptiveCooldownPollIntervalCeiling: TimeInterval = 0.05
    package static let adaptiveCooldownStableSamplesRequired = 2
    package static let topologyStabilityAdaptiveProbeDivisor: TimeInterval = 6
    package static let topologyStabilityAdaptiveBackoffMultiplier: TimeInterval = 1.5
}
package enum ManagedVirtualDisplayIdentity {
    package static let vendorID: UInt32 = 0x3456
    package static let productID: UInt32 = 0x1234
}
package struct ManagedVirtualDisplayRuntimeSnapshot: Equatable {
    package let configId: UUID
    package let serialNum: UInt32
    package let displayID: CGDirectDisplayID
    package let isLiveRuntime: Bool

    package init(
        configId: UUID,
        serialNum: UInt32,
        displayID: CGDirectDisplayID,
        isLiveRuntime: Bool
    ) {
        self.configId = configId
        self.serialNum = serialNum
        self.displayID = displayID
        self.isLiveRuntime = isLiveRuntime
    }
}
package struct VirtualDisplaySnapshot: Equatable {
    package let managedDisplays: [ManagedVirtualDisplayRuntimeSnapshot]
    package let configs: [VirtualDisplayConfig]
    package let runningConfigIds: Set<UUID>
    package let restoreFailures: [VirtualDisplayRestoreFailure]
    package let configStorePresentation: VirtualDisplayConfigStorePresentation
    package let runtimeDisplayIDByConfigId: [UUID: CGDirectDisplayID]

    package init(
        managedDisplays: [ManagedVirtualDisplayRuntimeSnapshot],
        configs: [VirtualDisplayConfig],
        runningConfigIds: Set<UUID>,
        restoreFailures: [VirtualDisplayRestoreFailure],
        configStorePresentation: VirtualDisplayConfigStorePresentation,
        runtimeDisplayIDByConfigId: [UUID: CGDirectDisplayID]
    ) {
        self.managedDisplays = managedDisplays
        self.configs = configs
        self.runningConfigIds = runningConfigIds
        self.restoreFailures = restoreFailures
        self.configStorePresentation = configStorePresentation
        self.runtimeDisplayIDByConfigId = runtimeDisplayIDByConfigId
    }

    package func runtimeDisplayID(for configId: UUID) -> CGDirectDisplayID? {
        runtimeDisplayIDByConfigId[configId]
    }

    package func isManagedDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        managedDisplays.contains(where: { $0.displayID == displayID })
    }

    package func serialForManagedDisplay(_ displayID: CGDirectDisplayID) -> UInt32? {
        managedDisplays.first(where: { $0.displayID == displayID })?.serialNum
    }
}
package struct RuntimeDisplayRecord: Equatable {
    package let configId: UUID
    package let serialNum: UInt32
    package let displayID: CGDirectDisplayID
    package let generation: UInt64
}
