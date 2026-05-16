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

package enum VirtualDisplayStartupRestoreConfigLoadStatus: Equatable, Sendable {
    case succeeded
    case failed
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

package enum VirtualDisplayStartupRestoreCommandOutcome: Equatable, Sendable {
    case notAttempted
    case succeeded
    case failed
    case invalidated
    case partiallySucceeded
}

package enum VirtualDisplayRuntimeTrackingClearOutcome: Equatable, Sendable {
    case notAttempted
    case cleared
    case failed
}

package struct VirtualDisplayStartupRestoreConfigLoadResult: Equatable, Sendable {
    package let status: VirtualDisplayStartupRestoreConfigLoadStatus
    package let configs: [VirtualDisplayConfig]
    package let failureReason: String?
    package let underlyingDomain: String?
    package let underlyingCode: Int?

    package init(
        status: VirtualDisplayStartupRestoreConfigLoadStatus,
        configs: [VirtualDisplayConfig],
        failureReason: String? = nil,
        underlyingDomain: String? = nil,
        underlyingCode: Int? = nil
    ) {
        self.status = status
        self.configs = configs
        self.failureReason = failureReason
        self.underlyingDomain = underlyingDomain
        self.underlyingCode = underlyingCode
    }

    package static func succeeded(configs: [VirtualDisplayConfig]) -> Self {
        Self(status: .succeeded, configs: configs)
    }

    package static func failed(
        reason: String,
        underlyingDomain: String? = nil,
        underlyingCode: Int? = nil
    ) -> Self {
        Self(
            status: .failed,
            configs: [],
            failureReason: reason,
            underlyingDomain: underlyingDomain,
            underlyingCode: underlyingCode
        )
    }
}

package struct VirtualDisplayStartupRestoreCommandRequest: Equatable, Sendable {
    package let transactionID: UUID
    package let runID: UUID
    package let configID: UUID

    package init(
        transactionID: UUID,
        runID: UUID,
        configID: UUID
    ) {
        self.transactionID = transactionID
        self.runID = runID
        self.configID = configID
    }
}

package struct VirtualDisplayStartupRestoreCommandResult: Equatable, Sendable {
    package let transactionID: UUID
    package let configID: UUID
    package let preDisplayID: CGDirectDisplayID?
    package let postDisplayID: CGDirectDisplayID?
    package let restoreOutcome: VirtualDisplayStartupRestoreCommandOutcome
    package let didProduceVerifiableSideEffect: Bool
    package let failureReason: String?
    package let compensationOutcome: VirtualDisplayStartupRestoreCommandOutcome
    package let compensationFailureReason: String?

    package init(
        transactionID: UUID,
        configID: UUID,
        preDisplayID: CGDirectDisplayID?,
        postDisplayID: CGDirectDisplayID?,
        restoreOutcome: VirtualDisplayStartupRestoreCommandOutcome,
        didProduceVerifiableSideEffect: Bool,
        failureReason: String? = nil,
        compensationOutcome: VirtualDisplayStartupRestoreCommandOutcome = .notAttempted,
        compensationFailureReason: String? = nil
    ) {
        self.transactionID = transactionID
        self.configID = configID
        self.preDisplayID = preDisplayID
        self.postDisplayID = postDisplayID
        self.restoreOutcome = restoreOutcome
        self.didProduceVerifiableSideEffect = didProduceVerifiableSideEffect
        self.failureReason = failureReason
        self.compensationOutcome = compensationOutcome
        self.compensationFailureReason = compensationFailureReason
    }
}

package struct VirtualDisplayCreateCommandResult: Equatable, Sendable {
    package let createdConfigID: UUID?
    package let persistenceOutcome: VirtualDisplayCommandPersistenceOutcome
    package let runtimeCreationOutcome: VirtualDisplayCommandRuntimeOutcome
    package let rollbackOutcome: VirtualDisplayCommandPersistenceOutcome

    package init(
        createdConfigID: UUID?,
        persistenceOutcome: VirtualDisplayCommandPersistenceOutcome,
        runtimeCreationOutcome: VirtualDisplayCommandRuntimeOutcome,
        rollbackOutcome: VirtualDisplayCommandPersistenceOutcome
    ) {
        self.createdConfigID = createdConfigID
        self.persistenceOutcome = persistenceOutcome
        self.runtimeCreationOutcome = runtimeCreationOutcome
        self.rollbackOutcome = rollbackOutcome
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

    package init(
        configID: UUID,
        targetWasRunning: Bool,
        preDisplayID: CGDirectDisplayID?,
        postDisplayID: CGDirectDisplayID?,
        persistenceOutcome: VirtualDisplayCommandPersistenceOutcome,
        virtualDisplayCommandOutcome: VirtualDisplayCommandRuntimeOutcome,
        runtimeTrackingClearOutcome: VirtualDisplayRuntimeTrackingClearOutcome
    ) {
        self.configID = configID
        self.targetWasRunning = targetWasRunning
        self.preDisplayID = preDisplayID
        self.postDisplayID = postDisplayID
        self.persistenceOutcome = persistenceOutcome
        self.virtualDisplayCommandOutcome = virtualDisplayCommandOutcome
        self.runtimeTrackingClearOutcome = runtimeTrackingClearOutcome
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
    func loadPersistedVirtualDisplayConfigsForStartupRestoreCommand() -> VirtualDisplayStartupRestoreConfigLoadResult
    func restoreVirtualDisplayForStartupCommand(
        _ request: VirtualDisplayStartupRestoreCommandRequest
    ) -> VirtualDisplayStartupRestoreCommandResult
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
