import Foundation

enum VirtualDisplayReorderDirection {
    case up
    case down
}

enum VirtualDisplayTopologyRecoveryMode {
    case fast
    case aggressive
}

extension VirtualDisplayTopologyRecoveryMode {
    var logDescription: String {
        switch self {
        case .fast: return "fast"
        case .aggressive: return "aggressive"
        }
    }
}

struct VirtualDisplayAdaptiveCooldownResult {
    let waitedSeconds: TimeInterval
    let completedEarly: Bool
}

enum VirtualDisplayOperationError: LocalizedError {
    case duplicateSerialNumber(UInt32)
    case invalidConfiguration(String)
    case creationFailed
    case configNotFound
    case teardownTimedOut
    case topologyRepairFailed
    case topologyUnstableAfterEnable

    var errorDescription: String? {
        switch self {
        case .duplicateSerialNumber(let num):
            return String(localized: "Serial number \(num) is already in use.")
        case .invalidConfiguration(let reason):
            return String(localized: "Invalid configuration: \(reason)")
        case .creationFailed:
            return String(localized: "Virtual display creation failed.")
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

enum VirtualDisplayTimingPolicy {
    static let rollbackOfflineWaitTimeout: TimeInterval = 1.2
    static let rebuildTerminationTimeout: TimeInterval = 2.0
    static let rebuildOfflineTimeout: TimeInterval = 4.0
    static let rebuildFinalOfflineConfirmationTimeout: TimeInterval = 0.8
    static let rebuildFleetCreationCooldown: TimeInterval = 0.6
    static let rebuildFleetCreationCooldownFastTeardown: TimeInterval = 0.15
    static let deferredTopologyRecheckMinimumDelay: TimeInterval = 0.03
    static let deferredTopologyRecheckMultiplier: TimeInterval = 1.5
    static let aggressiveEnableUnsettledTeardownCooldown: TimeInterval = 0.35
    static let adaptiveCooldownPollIntervalFloor: TimeInterval = 0.01
    static let adaptiveCooldownPollIntervalCeiling: TimeInterval = 0.05
    static let adaptiveCooldownStableSamplesRequired = 2
    static let topologyStabilityAdaptiveProbeDivisor: TimeInterval = 6
    static let topologyStabilityAdaptiveBackoffMultiplier: TimeInterval = 1.5
}

enum ManagedVirtualDisplayIdentity {
    static let vendorID: UInt32 = 0x3456
    static let productID: UInt32 = 0x1234
}
