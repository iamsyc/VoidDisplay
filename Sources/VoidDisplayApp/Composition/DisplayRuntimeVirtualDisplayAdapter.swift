import Foundation
import VoidDisplayRuntime
import VoidDisplayVirtualDisplay

@MainActor
package final class DisplayRuntimeVirtualDisplayAdapter: DisplayRuntimeVirtualDisplayProviding, DisplayRuntimeVirtualDisplayCommanding {
    private weak var controller: VirtualDisplayController?

    package init(controller: VirtualDisplayController) {
        self.controller = controller
    }

    package func makeVirtualDisplaySnapshot() -> DisplayRuntimeVirtualDisplaySnapshot {
        guard let controller else { return .empty }
        return DisplayRuntimeVirtualDisplaySnapshot(adapterController: controller)
    }

    package func rebuildVirtualDisplay(configID: UUID) async throws -> DisplayRuntimeVirtualDisplayRebuildCommandResult {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        let preDisplayID = controller.runtimeDisplayID(for: configID)
        try await controller.rebuildVirtualDisplay(configId: configID)
        return DisplayRuntimeVirtualDisplayRebuildCommandResult(
            configID: configID,
            preDisplayID: preDisplayID,
            postDisplayID: controller.runtimeDisplayID(for: configID),
            runningConfigIDsAfterCommand: controller.runningConfigIds,
            managedDisplaysAfterCommand: controller.managedDisplays
        )
    }

    package func preflightEnableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayEnablePreflight {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        let preflight = controller.enableDisplayPreflight(request.configID)
        return DisplayRuntimeVirtualDisplayEnablePreflight(
            configID: preflight.configID,
            targetPreDisplayID: preflight.targetPreDisplayID,
            mayPerformFleetRebuild: preflight.mayPerformFleetRebuild,
            requiresFleetQuiesce: preflight.requiresFleetQuiesce,
            scopeEscalationReason: DisplayRuntimeScopeEscalationReason(preflight.scopeEscalationReason)
        )
    }

    package func setVirtualDisplayDesiredEnabled(
        request: DisplayRuntimeVirtualDisplayDesiredEnabledCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayDesiredEnabledCommandResult {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        try controller.setDesiredEnabled(request.configID, enabled: request.enabled)
        return DisplayRuntimeVirtualDisplayDesiredEnabledCommandResult(
            configID: request.configID,
            desiredEnabled: request.enabled,
            persistenceOutcome: .saved
        )
    }

    package func saveConfigForRebuild(
        request: DisplayRuntimeVirtualDisplayEditRebuildRequest
    ) async throws -> DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        let updated = VirtualDisplayConfig(editDTO: request.editedConfig)
        do {
            let previous = try controller.saveConfigForRebuildCommand(
                updated,
                expectedConfigFingerprint: request.expectedConfigFingerprint
            )
            return DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult(
                configID: updated.id,
                persistenceOutcome: .saved,
                previousConfigForCompensation: DisplayRuntimeVirtualDisplayConfigEditDTO(adapterConfig: previous),
                savedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence(
                    config: DisplayRuntimeVirtualDisplayConfigEditDTO(adapterConfig: updated)
                )
            )
        } catch VirtualDisplayEditRebuildPersistenceError.editRequestStale {
            throw DisplayRuntimeVirtualDisplayEditRebuildSaveCommandError.editRequestStale
        }
    }

    package func restoreConfigAfterFailedEdit(
        request: DisplayRuntimeVirtualDisplayEditRebuildRestoreCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayPersistenceCommandResult {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        let previous = VirtualDisplayConfig(editDTO: request.previousConfigForCompensation)
        try controller.restoreConfigAfterFailedEditCommand(previous)
        return DisplayRuntimeVirtualDisplayPersistenceCommandResult(
            configID: previous.id,
            persistenceOutcome: .rolledBack
        )
    }

    package func enableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayLifecycleCommandResult {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        let result = try await controller.enableRuntimeDisplay(request.configID)
        return DisplayRuntimeVirtualDisplayLifecycleCommandResult(
            lowerResult: result,
            request: request,
            runningConfigIDsAfterCommand: controller.runningConfigIds,
            managedDisplaysAfterCommand: controller.managedDisplays
        )
    }

    package func disableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayLifecycleCommandResult {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        let result = try controller.disableRuntimeDisplayByConfig(request.configID)
        return DisplayRuntimeVirtualDisplayLifecycleCommandResult(
            lowerResult: result,
            request: request,
            runningConfigIDsAfterCommand: controller.runningConfigIds,
            managedDisplaysAfterCommand: controller.managedDisplays
        )
    }

    package func createVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayCreateRequest
    ) async throws -> DisplayRuntimeVirtualDisplayCreateCommandResult {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        let commandRequest = VirtualDisplayCreateRequest(runtimeRequest: request)
        do {
            let result = try controller.createDisplayCommand(commandRequest)
            return DisplayRuntimeVirtualDisplayCreateCommandResult(
                transactionID: request.transactionID,
                lowerResult: result
            )
        } catch let failure as VirtualDisplayCreateCommandFailure {
            throw DisplayRuntimeVirtualDisplayCreateCommandError(
                reason: failure.reason,
                result: DisplayRuntimeVirtualDisplayCreateCommandResult(
                    transactionID: request.transactionID,
                    lowerResult: failure.result
                )
            )
        }
    }

    package func deleteVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayDeleteCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayDeleteCommandResult {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        do {
            let result = try controller.deleteDisplayCommand(configId: request.configID)
            return DisplayRuntimeVirtualDisplayDeleteCommandResult(
                transactionID: request.transactionID,
                lowerResult: result
            )
        } catch let failure as VirtualDisplayDeleteCommandFailure {
            throw DisplayRuntimeVirtualDisplayDeleteCommandError(
                reason: failure.reason,
                result: DisplayRuntimeVirtualDisplayDeleteCommandResult(
                    transactionID: request.transactionID,
                    lowerResult: failure.result
                )
            )
        }
    }
}

private enum DisplayRuntimeAdapterError: LocalizedError {
    case adapterUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .adapterUnavailable(let reason):
            reason
        }
    }
}
