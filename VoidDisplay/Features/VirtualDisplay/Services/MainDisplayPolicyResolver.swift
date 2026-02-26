import CoreGraphics
import Foundation
import OSLog

/// Owns main display policy resolution and aggressive recovery state tracking.
@MainActor
final class MainDisplayPolicyResolver {
    enum PolicySource {
        case listOrder
        case fallbackCurrentManagedMain
        case policyDisabledPhysicalPresent
        case policyDisabledTooFewEnabled
        case policyDisabledNoSnapshot

        var logDescription: String {
            switch self {
            case .listOrder: return "listOrder"
            case .fallbackCurrentManagedMain: return "fallbackCurrentManagedMain"
            case .policyDisabledPhysicalPresent: return "disabledPhysicalPresent"
            case .policyDisabledTooFewEnabled: return "disabledTooFewEnabled"
            case .policyDisabledNoSnapshot: return "disabledNoSnapshot"
            }
        }
    }

    struct PolicyResolution {
        let applies: Bool
        let source: PolicySource
        let targetConfigID: UUID?
        let targetSerial: UInt32?
        let targetDisplayID: CGDirectDisplayID?
        let enabledDesiredCount: Int
        let hasPhysicalDisplay: Bool?
        let preferredMainDisplayID: CGDirectDisplayID?
    }

    private var aggressiveRecoveryPendingEnableConfigIDs: Set<UUID> = []

    /// Provides enabled desired configs in list order.
    private let enabledDesiredConfigsProvider: () -> [VirtualDisplayConfig]
    /// Provides a runtime display ID for a given config ID.
    private let runtimeDisplayIDProvider: (UUID) -> CGDirectDisplayID?
    /// Provides all configs (needed for serial-based lookup).
    private let allConfigsProvider: () -> [VirtualDisplayConfig]

    init(
        enabledDesiredConfigsProvider: @escaping () -> [VirtualDisplayConfig],
        runtimeDisplayIDProvider: @escaping (UUID) -> CGDirectDisplayID?,
        allConfigsProvider: @escaping () -> [VirtualDisplayConfig]
    ) {
        self.enabledDesiredConfigsProvider = enabledDesiredConfigsProvider
        self.runtimeDisplayIDProvider = runtimeDisplayIDProvider
        self.allConfigsProvider = allConfigsProvider
    }

    // MARK: - Resolve

    func resolveMainDisplayPolicy(
        snapshot: DisplayTopologySnapshot?,
        emitLog: Bool = true
    ) -> PolicyResolution {
        let enabledDesiredConfigs = enabledDesiredConfigsProvider()
        let enabledDesiredCount = enabledDesiredConfigs.count
        let fallbackCurrentManagedMain = TopologyHealthEvaluator.preferredManagedMainDisplayID(
            snapshot: snapshot
        )

        let resolution: PolicyResolution
        guard let snapshot else {
            resolution = PolicyResolution(
                applies: false,
                source: .policyDisabledNoSnapshot,
                targetConfigID: nil,
                targetSerial: nil,
                targetDisplayID: nil,
                enabledDesiredCount: enabledDesiredCount,
                hasPhysicalDisplay: nil,
                preferredMainDisplayID: fallbackCurrentManagedMain
            )
            if emitLog { logPolicyResolution(resolution) }
            return resolution
        }

        let hasPhysicalDisplay = snapshot.displays.contains {
            !$0.isManagedVirtualDisplay && $0.isViable
        }
        if hasPhysicalDisplay {
            resolution = PolicyResolution(
                applies: false,
                source: .policyDisabledPhysicalPresent,
                targetConfigID: nil,
                targetSerial: nil,
                targetDisplayID: nil,
                enabledDesiredCount: enabledDesiredCount,
                hasPhysicalDisplay: true,
                preferredMainDisplayID: fallbackCurrentManagedMain
            )
            if emitLog { logPolicyResolution(resolution) }
            return resolution
        }

        guard enabledDesiredCount >= 2 else {
            resolution = PolicyResolution(
                applies: false,
                source: .policyDisabledTooFewEnabled,
                targetConfigID: nil,
                targetSerial: nil,
                targetDisplayID: nil,
                enabledDesiredCount: enabledDesiredCount,
                hasPhysicalDisplay: false,
                preferredMainDisplayID: fallbackCurrentManagedMain
            )
            if emitLog { logPolicyResolution(resolution) }
            return resolution
        }

        guard let targetConfig = enabledDesiredConfigs.first else {
            resolution = PolicyResolution(
                applies: false,
                source: .fallbackCurrentManagedMain,
                targetConfigID: nil,
                targetSerial: nil,
                targetDisplayID: nil,
                enabledDesiredCount: enabledDesiredCount,
                hasPhysicalDisplay: false,
                preferredMainDisplayID: fallbackCurrentManagedMain
            )
            if emitLog { logPolicyResolution(resolution) }
            return resolution
        }

        let targetDisplayID = runtimeDisplayIDProvider(targetConfig.id)
        resolution = PolicyResolution(
            applies: true,
            source: .listOrder,
            targetConfigID: targetConfig.id,
            targetSerial: targetConfig.serialNum,
            targetDisplayID: targetDisplayID,
            enabledDesiredCount: enabledDesiredCount,
            hasPhysicalDisplay: false,
            preferredMainDisplayID: targetDisplayID
        )
        if emitLog { logPolicyResolution(resolution) }
        return resolution
    }

    // MARK: - Reconcile

    func reconcileMainDisplayPolicyIfNeeded(
        snapshot: DisplayTopologySnapshot?,
        ensureHealthyTopology: (CGDirectDisplayID?) async throws -> Void
    ) async throws {
        let resolution = resolveMainDisplayPolicy(snapshot: snapshot)
        guard resolution.applies else { return }
        guard let snapshot else {
            return
        }
        guard let preferredMainDisplayID = resolution.targetDisplayID else {
            AppLog.virtualDisplay.debug(
                "Main display policy reconcile deferred because target runtime display is not yet available (targetConfig: \(String(describing: resolution.targetConfigID), privacy: .public), targetSerial: \(String(describing: resolution.targetSerial), privacy: .public))."
            )
            return
        }
        guard snapshot.display(for: preferredMainDisplayID) != nil else {
            AppLog.virtualDisplay.debug(
                "Main display policy reconcile deferred because target runtime display is not visible in current snapshot (targetConfig: \(String(describing: resolution.targetConfigID), privacy: .public), targetSerial: \(String(describing: resolution.targetSerial), privacy: .public), targetRuntimeDisplayID: \(preferredMainDisplayID, privacy: .public))."
            )
            return
        }
        let allConfigs = allConfigsProvider()
        let desiredManagedSerials = Set(allConfigs.filter(\.desiredEnabled).map(\.serialNum))
        let visibleDesiredManagedCount = snapshot.displays.filter {
            $0.isManagedVirtualDisplay && desiredManagedSerials.contains($0.serialNumber) && $0.isViable
        }.count
        guard visibleDesiredManagedCount >= 2 else {
            AppLog.virtualDisplay.debug(
                "Main display policy reconcile skipped because visible desired managed displays are insufficient (visibleDesiredManagedCount: \(visibleDesiredManagedCount, privacy: .public), desiredEnabledCount: \(resolution.enabledDesiredCount, privacy: .public))."
            )
            return
        }
        let evaluation = TopologyHealthEvaluator.evaluate(
            snapshot: snapshot,
            desiredManagedSerials: desiredManagedSerials
        )
        let continuityRepairNeeded = TopologyHealthEvaluator.shouldEnforceMainContinuity(
            preferredMainDisplayID: preferredMainDisplayID,
            snapshot: snapshot,
            managedDisplayIDs: evaluation.managedDisplayIDs
        )
        if !evaluation.needsRepair && !continuityRepairNeeded {
            let managedIDsDescription = evaluation.managedDisplayIDs.map(String.init).joined(separator: ",")
            AppLog.virtualDisplay.debug(
                "Main display policy reconcile skipped because topology is already healthy and main continuity is satisfied (preferredMain: \(preferredMainDisplayID, privacy: .public), main: \(snapshot.mainDisplayID, privacy: .public), managedIDs: \(managedIDsDescription, privacy: .public))."
            )
            return
        }
        try await ensureHealthyTopology(preferredMainDisplayID)
    }

    // MARK: - Aggressive recovery tracking

    func markAggressiveRecoveryPending(configId: UUID) {
        aggressiveRecoveryPendingEnableConfigIDs.insert(configId)
    }

    func isAggressiveRecoveryPending(configId: UUID) -> Bool {
        aggressiveRecoveryPendingEnableConfigIDs.contains(configId)
    }

    func markAggressiveRecoveryPendingForSerial(_ serialNum: UInt32) {
        let configs = allConfigsProvider()
        for config in configs where config.serialNum == serialNum {
            aggressiveRecoveryPendingEnableConfigIDs.insert(config.id)
        }
    }

    func clearAggressiveRecoveryPending(configId: UUID) {
        aggressiveRecoveryPendingEnableConfigIDs.remove(configId)
    }

    func clearAggressiveRecoveryPendingForSerial(_ serialNum: UInt32) {
        let configs = allConfigsProvider()
        let ids = configs
            .filter { $0.serialNum == serialNum }
            .map(\.id)
        aggressiveRecoveryPendingEnableConfigIDs.subtract(ids)
    }

    func resetAll() {
        aggressiveRecoveryPendingEnableConfigIDs.removeAll()
    }

    // MARK: - Logging

    private func logPolicyResolution(_ resolution: PolicyResolution) {
        AppLog.virtualDisplay.debug(
            "Main display policy resolved (applies: \(resolution.applies, privacy: .public), source: \(resolution.source.logDescription, privacy: .public), targetConfig: \(String(describing: resolution.targetConfigID?.uuidString), privacy: .public), targetSerial: \(String(describing: resolution.targetSerial), privacy: .public), targetRuntimeDisplayID: \(String(describing: resolution.targetDisplayID), privacy: .public), enabledDesiredCount: \(resolution.enabledDesiredCount, privacy: .public), hasPhysicalDisplay: \(String(describing: resolution.hasPhysicalDisplay), privacy: .public))."
        )
    }
}
