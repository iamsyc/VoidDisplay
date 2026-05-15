import CoreGraphics
import Foundation
import VoidDisplayRuntime
import VoidDisplayVirtualDisplay

@MainActor
package final class DisplayRuntimeVirtualDisplayAdapter: DisplayRuntimeVirtualDisplayProviding, DisplayRuntimeVirtualDisplayCommanding, DisplayRuntimeStartupRestoreCommanding {
    private weak var controller: VirtualDisplayController?
    private let commandFacade: any VirtualDisplayFacade

    package init(
        controller: VirtualDisplayController,
        commandFacade: any VirtualDisplayFacade
    ) {
        self.controller = controller
        self.commandFacade = commandFacade
    }

    package func makeVirtualDisplaySnapshot() -> DisplayRuntimeVirtualDisplaySnapshot {
        DisplayRuntimeVirtualDisplaySnapshot(
            adapterController: controller,
            commandSnapshot: commandFacade.snapshot
        )
    }

    package func rebuildVirtualDisplay(configID: UUID) async throws -> DisplayRuntimeVirtualDisplayRebuildCommandResult {
        let preDisplayID = commandFacade.snapshot.runtimeDisplayIDByConfigId[configID]
        try await commandFacade.rebuildVirtualDisplay(configId: configID)
        let snapshot = commandFacade.snapshot
        return DisplayRuntimeVirtualDisplayRebuildCommandResult(
            configID: configID,
            preDisplayID: preDisplayID,
            postDisplayID: snapshot.runtimeDisplayIDByConfigId[configID],
            runningConfigIDsAfterCommand: snapshot.runningConfigIds,
            managedDisplaysAfterCommand: snapshot.managedDisplays
        )
    }

    package func preflightEnableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayEnablePreflight {
        let preflight = commandFacade.enableDisplayPreflight(request.configID)
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
        try commandFacade.setDesiredEnabled(request.configID, enabled: request.enabled)
        return DisplayRuntimeVirtualDisplayDesiredEnabledCommandResult(
            configID: request.configID,
            desiredEnabled: request.enabled,
            persistenceOutcome: .saved
        )
    }

    package func saveConfigForRebuild(
        request: DisplayRuntimeVirtualDisplayEditRebuildRequest
    ) async throws -> DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult {
        let updated = VirtualDisplayConfig(editDTO: request.editedConfig)
        do {
            guard let previous = commandFacade.configForEditRebuild(updated.id) else {
                throw VirtualDisplayOperationError.configNotFound
            }
            guard previous.editRebuildFingerprint == request.expectedConfigFingerprint else {
                throw VirtualDisplayEditRebuildPersistenceError.editRequestStale
            }
            try commandFacade.saveConfigForRebuild(updated)
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
        let previous = VirtualDisplayConfig(editDTO: request.previousConfigForCompensation)
        try commandFacade.restoreConfigAfterFailedEdit(previous)
        return DisplayRuntimeVirtualDisplayPersistenceCommandResult(
            configID: previous.id,
            persistenceOutcome: .rolledBack
        )
    }

    package func enableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayLifecycleCommandResult {
        let result = try await commandFacade.enableRuntimeDisplay(request.configID)
        let snapshot = commandFacade.snapshot
        return DisplayRuntimeVirtualDisplayLifecycleCommandResult(
            lowerResult: result,
            request: request,
            runningConfigIDsAfterCommand: snapshot.runningConfigIds,
            managedDisplaysAfterCommand: snapshot.managedDisplays
        )
    }

    package func disableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayLifecycleCommandResult {
        let result = try commandFacade.disableRuntimeDisplayByConfig(request.configID)
        let snapshot = commandFacade.snapshot
        return DisplayRuntimeVirtualDisplayLifecycleCommandResult(
            lowerResult: result,
            request: request,
            runningConfigIDsAfterCommand: snapshot.runningConfigIds,
            managedDisplaysAfterCommand: snapshot.managedDisplays
        )
    }

    package func createVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayCreateRequest
    ) async throws -> DisplayRuntimeVirtualDisplayCreateCommandResult {
        do {
            let result = try commandFacade.createDisplayCommand(
                name: request.displayName,
                serialNum: request.serialNumber,
                physicalSize: CGSize(
                    width: CGFloat(request.physicalWidthMillimeters),
                    height: CGFloat(request.physicalHeightMillimeters)
                ),
                maxPixels: (
                    width: request.maximumPixelWidth,
                    height: request.maximumPixelHeight
                ),
                modes: request.modes.resolutionSelections
            )
            let snapshot = commandFacade.snapshot
            return DisplayRuntimeVirtualDisplayCreateCommandResult(
                transactionID: request.transactionID,
                lowerResult: result,
                request: request,
                runningConfigIDsAfterCommand: snapshot.runningConfigIds,
                managedDisplaysAfterCommand: snapshot.managedDisplays
            )
        } catch let failure as VirtualDisplayCreateCommandFailure {
            let snapshot = commandFacade.snapshot
            throw DisplayRuntimeVirtualDisplayCreateCommandError(
                reason: failure.reason,
                result: DisplayRuntimeVirtualDisplayCreateCommandResult(
                    transactionID: request.transactionID,
                    lowerResult: failure.result,
                    request: request,
                    runningConfigIDsAfterCommand: snapshot.runningConfigIds,
                    managedDisplaysAfterCommand: snapshot.managedDisplays
                )
            )
        }
    }

    package func deleteVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayDeleteCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayDeleteCommandResult {
        do {
            let result = try commandFacade.deleteDisplayCommand(request.configID)
            let snapshot = commandFacade.snapshot
            return DisplayRuntimeVirtualDisplayDeleteCommandResult(
                transactionID: request.transactionID,
                lowerResult: result,
                runningConfigIDsAfterCommand: snapshot.runningConfigIds,
                managedDisplaysAfterCommand: snapshot.managedDisplays
            )
        } catch let failure as VirtualDisplayDeleteCommandFailure {
            let snapshot = commandFacade.snapshot
            throw DisplayRuntimeVirtualDisplayDeleteCommandError(
                reason: failure.reason,
                result: DisplayRuntimeVirtualDisplayDeleteCommandResult(
                    transactionID: request.transactionID,
                    lowerResult: failure.result,
                    runningConfigIDsAfterCommand: snapshot.runningConfigIds,
                    managedDisplaysAfterCommand: snapshot.managedDisplays
                )
            )
        }
    }

    package func loadPersistedVirtualDisplayConfigsForStartupRestore()
        async -> DisplayRuntimeStartupRestoreConfigLoadResult
    {
        let result = commandFacade.loadPersistedVirtualDisplayConfigsForStartupRestoreCommand()
        return DisplayRuntimeStartupRestoreConfigLoadResult(lowerResult: result)
    }

    package func restoreVirtualDisplayForStartup(
        request: DisplayRuntimeStartupRestoreCommandRequest
    ) async throws -> DisplayRuntimeStartupRestoreCommandResult {
        let lowerRequest = VirtualDisplayStartupRestoreCommandRequest(runtimeRequest: request)
        let result = commandFacade.restoreVirtualDisplayForStartupCommand(lowerRequest)
        let snapshot = commandFacade.snapshot
        return DisplayRuntimeStartupRestoreCommandResult(
            runtimeRequest: request,
            lowerResult: result,
            runningConfigIDsAfterCommand: snapshot.runningConfigIds,
            managedDisplaysAfterCommand: snapshot.managedDisplays
        )
    }
}
