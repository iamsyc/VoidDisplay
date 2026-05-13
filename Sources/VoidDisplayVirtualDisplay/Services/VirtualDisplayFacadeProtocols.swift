import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import Foundation

package struct VirtualDisplayEnablePreflight: Equatable, Sendable {
    package enum ScopeEscalationReason: Equatable, Sendable {
        case enableMayPerformFleetRebuild
    }

    package let configID: UUID
    package let targetPreDisplayID: CGDirectDisplayID?
    package let mayPerformFleetRebuild: Bool
    package let requiresFleetQuiesce: Bool
    package let scopeEscalationReason: ScopeEscalationReason?

    package init(
        configID: UUID,
        targetPreDisplayID: CGDirectDisplayID?,
        mayPerformFleetRebuild: Bool,
        requiresFleetQuiesce: Bool,
        scopeEscalationReason: ScopeEscalationReason?
    ) {
        self.configID = configID
        self.targetPreDisplayID = targetPreDisplayID
        self.mayPerformFleetRebuild = mayPerformFleetRebuild
        self.requiresFleetQuiesce = requiresFleetQuiesce
        self.scopeEscalationReason = scopeEscalationReason
    }
}

package struct VirtualDisplayLifecycleCommandResult: Equatable, Sendable {
    package let configID: UUID
    package let desiredEnabled: Bool
    package let preDisplayID: CGDirectDisplayID?
    package let postDisplayID: CGDirectDisplayID?
    package let mayPerformFleetRebuild: Bool
    package let requiresFleetQuiesce: Bool

    package init(
        configID: UUID,
        desiredEnabled: Bool,
        preDisplayID: CGDirectDisplayID?,
        postDisplayID: CGDirectDisplayID?,
        mayPerformFleetRebuild: Bool,
        requiresFleetQuiesce: Bool
    ) {
        self.configID = configID
        self.desiredEnabled = desiredEnabled
        self.preDisplayID = preDisplayID
        self.postDisplayID = postDisplayID
        self.mayPerformFleetRebuild = mayPerformFleetRebuild
        self.requiresFleetQuiesce = requiresFleetQuiesce
    }
}

package enum VirtualDisplayCommandPersistenceOutcome: Equatable, Sendable {
    case notAttempted
    case saved
    case failed
    case rolledBack
    case rollbackFailed
}

package enum VirtualDisplayCommandRuntimeOutcome: Equatable, Sendable {
    case notAttempted
    case succeeded
    case failed
}

package enum VirtualDisplayRuntimeTrackingClearOutcome: Equatable, Sendable {
    case notAttempted
    case cleared
    case failed
}

package struct VirtualDisplayCommandConfigEvidence: Equatable, Sendable {
    package let id: UUID?
    package let serialNumber: UInt32
    package let desiredEnabled: Bool
    package let physicalWidthMillimeters: UInt32
    package let physicalHeightMillimeters: UInt32
    package let modeCount: Int
    package let maximumPixelWidth: UInt32
    package let maximumPixelHeight: UInt32

    package init(
        id: UUID?,
        serialNumber: UInt32,
        desiredEnabled: Bool,
        physicalWidthMillimeters: UInt32,
        physicalHeightMillimeters: UInt32,
        modeCount: Int,
        maximumPixelWidth: UInt32,
        maximumPixelHeight: UInt32
    ) {
        self.id = id
        self.serialNumber = serialNumber
        self.desiredEnabled = desiredEnabled
        self.physicalWidthMillimeters = physicalWidthMillimeters
        self.physicalHeightMillimeters = physicalHeightMillimeters
        self.modeCount = modeCount
        self.maximumPixelWidth = maximumPixelWidth
        self.maximumPixelHeight = maximumPixelHeight
    }
}

package struct VirtualDisplayCreateCommandResult: Equatable, Sendable {
    package let createdConfigID: UUID?
    package let serialNumber: UInt32
    package let targetWasRunningAfterCommand: Bool
    package let preDisplayID: CGDirectDisplayID?
    package let postDisplayID: CGDirectDisplayID?
    package let persistenceOutcome: VirtualDisplayCommandPersistenceOutcome
    package let runtimeCreationOutcome: VirtualDisplayCommandRuntimeOutcome
    package let rollbackOutcome: VirtualDisplayCommandPersistenceOutcome
    package let createdConfigEvidence: VirtualDisplayCommandConfigEvidence
    package let runningConfigIDsAfterCommand: [UUID]
    package let managedDisplaysAfterCommand: [ManagedVirtualDisplayRuntimeSnapshot]

    package init(
        createdConfigID: UUID?,
        serialNumber: UInt32,
        targetWasRunningAfterCommand: Bool,
        preDisplayID: CGDirectDisplayID?,
        postDisplayID: CGDirectDisplayID?,
        persistenceOutcome: VirtualDisplayCommandPersistenceOutcome,
        runtimeCreationOutcome: VirtualDisplayCommandRuntimeOutcome,
        rollbackOutcome: VirtualDisplayCommandPersistenceOutcome,
        createdConfigEvidence: VirtualDisplayCommandConfigEvidence,
        runningConfigIDsAfterCommand: [UUID],
        managedDisplaysAfterCommand: [ManagedVirtualDisplayRuntimeSnapshot]
    ) {
        self.createdConfigID = createdConfigID
        self.serialNumber = serialNumber
        self.targetWasRunningAfterCommand = targetWasRunningAfterCommand
        self.preDisplayID = preDisplayID
        self.postDisplayID = postDisplayID
        self.persistenceOutcome = persistenceOutcome
        self.runtimeCreationOutcome = runtimeCreationOutcome
        self.rollbackOutcome = rollbackOutcome
        self.createdConfigEvidence = createdConfigEvidence
        self.runningConfigIDsAfterCommand = runningConfigIDsAfterCommand.sorted { $0.uuidString < $1.uuidString }
        self.managedDisplaysAfterCommand = managedDisplaysAfterCommand.sorted {
            $0.configId.uuidString < $1.configId.uuidString
        }
    }
}

package struct VirtualDisplayCreateCommandFailure: LocalizedError {
    package let reason: String
    package let result: VirtualDisplayCreateCommandResult
    package let underlyingError: (any Error)?

    package init(
        reason: String,
        result: VirtualDisplayCreateCommandResult,
        underlyingError: (any Error)?
    ) {
        self.reason = reason
        self.result = result
        self.underlyingError = underlyingError
    }

    package var errorDescription: String? {
        underlyingError?.localizedDescription
    }
}

package struct VirtualDisplayDeleteCommandResult: Equatable, Sendable {
    package let configID: UUID
    package let targetWasRunning: Bool
    package let preDisplayID: CGDirectDisplayID?
    package let postDisplayID: CGDirectDisplayID?
    package let persistenceOutcome: VirtualDisplayCommandPersistenceOutcome
    package let virtualDisplayCommandOutcome: VirtualDisplayCommandRuntimeOutcome
    package let runtimeTrackingClearOutcome: VirtualDisplayRuntimeTrackingClearOutcome
    package let runningConfigIDsAfterCommand: [UUID]
    package let managedDisplaysAfterCommand: [ManagedVirtualDisplayRuntimeSnapshot]

    package init(
        configID: UUID,
        targetWasRunning: Bool,
        preDisplayID: CGDirectDisplayID?,
        postDisplayID: CGDirectDisplayID?,
        persistenceOutcome: VirtualDisplayCommandPersistenceOutcome,
        virtualDisplayCommandOutcome: VirtualDisplayCommandRuntimeOutcome,
        runtimeTrackingClearOutcome: VirtualDisplayRuntimeTrackingClearOutcome,
        runningConfigIDsAfterCommand: [UUID],
        managedDisplaysAfterCommand: [ManagedVirtualDisplayRuntimeSnapshot]
    ) {
        self.configID = configID
        self.targetWasRunning = targetWasRunning
        self.preDisplayID = preDisplayID
        self.postDisplayID = postDisplayID
        self.persistenceOutcome = persistenceOutcome
        self.virtualDisplayCommandOutcome = virtualDisplayCommandOutcome
        self.runtimeTrackingClearOutcome = runtimeTrackingClearOutcome
        self.runningConfigIDsAfterCommand = runningConfigIDsAfterCommand.sorted { $0.uuidString < $1.uuidString }
        self.managedDisplaysAfterCommand = managedDisplaysAfterCommand.sorted {
            $0.configId.uuidString < $1.configId.uuidString
        }
    }
}

package struct VirtualDisplayDeleteCommandFailure: LocalizedError {
    package let reason: String
    package let result: VirtualDisplayDeleteCommandResult
    package let underlyingError: (any Error)?

    package init(
        reason: String,
        result: VirtualDisplayDeleteCommandResult,
        underlyingError: (any Error)?
    ) {
        self.reason = reason
        self.result = result
        self.underlyingError = underlyingError
    }

    package var errorDescription: String? {
        underlyingError?.localizedDescription
    }
}

@MainActor
package protocol VirtualDisplayQuerying: AnyObject {
    var snapshot: VirtualDisplaySnapshot { get }
    func nextAvailableSerialNumber() -> UInt32
}

@MainActor
package protocol VirtualDisplayCommanding: AnyObject {
    func loadPersistedConfigs()
    func restoreDesiredVirtualDisplays()
    func clearRestoreFailures()

    @discardableResult
    func resetAllVirtualDisplayData() throws -> Int

    @discardableResult
    func createDisplayCommand(
        name: String,
        serialNum: UInt32,
        physicalSize: CGSize,
        maxPixels: (width: UInt32, height: UInt32),
        modes: [ResolutionSelection]
    ) throws -> VirtualDisplayCreateCommandResult

    func setDesiredEnabled(_ configId: UUID, enabled: Bool) throws
    func enableDisplayPreflight(_ configId: UUID) -> VirtualDisplayEnablePreflight
    func enableRuntimeDisplay(_ configId: UUID) async throws -> VirtualDisplayLifecycleCommandResult
    func disableRuntimeDisplayByConfig(_ configId: UUID) throws -> VirtualDisplayLifecycleCommandResult
    func deleteDisplayCommand(_ configId: UUID) throws -> VirtualDisplayDeleteCommandResult
    func updateConfig(_ updated: VirtualDisplayConfig) throws
    func configForEditRebuild(_ configId: UUID) -> VirtualDisplayConfig?
    func saveConfigForRebuild(_ updated: VirtualDisplayConfig) throws
    func restoreConfigAfterFailedEdit(_ previous: VirtualDisplayConfig) throws
    func moveConfig(_ configId: UUID, direction: VirtualDisplayReorderDirection) throws -> Bool
    @discardableResult
    func moveConfigToFirstEnabledPosition(_ configId: UUID) throws -> Bool
    func applyModes(configId: UUID, modes: [ResolutionSelection])
    func rebuildVirtualDisplay(configId: UUID) async throws
    func reconcileMainDisplayPolicyIfNeeded() async throws
}

@MainActor
package protocol VirtualDisplayFacade: VirtualDisplayCommanding, VirtualDisplayQuerying {}

extension VirtualDisplayOrchestrator: VirtualDisplayFacade {}
