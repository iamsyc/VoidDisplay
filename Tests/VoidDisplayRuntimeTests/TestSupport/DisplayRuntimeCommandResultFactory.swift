@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation

func createRequest(
    displayName: String,
    serialNumber: UInt32
) -> DisplayRuntimeVirtualDisplayCreateRequest {
    .init(
        displayName: displayName,
        serialNumber: serialNumber,
        physicalWidthMillimeters: 600,
        physicalHeightMillimeters: 340,
        maximumPixelWidth: 1920,
        maximumPixelHeight: 1080,
        modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
        source: .createVirtualDisplaySheet
    )
}

func createCommandResult(
    transactionID: DisplayRuntimeTransactionID = DisplayRuntimeTransactionID(),
    createdConfigID: UUID? = UUID(),
    serialNumber: UInt32,
    targetWasRunningAfterCommand: Bool = true,
    preDisplayID: DisplayRuntimeDisplayID? = nil,
    postDisplayID: DisplayRuntimeDisplayID? = 9001,
    persistenceOutcome: DisplayRuntimePersistenceOutcome = .saved,
    runtimeCreationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome = .succeeded,
    rollbackOutcome: DisplayRuntimePersistenceOutcome = .notAttempted,
    physicalWidthMillimeters: UInt32 = 600,
    physicalHeightMillimeters: UInt32 = 340,
    modeCount: Int = 1,
    maximumPixelWidth: UInt32 = 1920,
    maximumPixelHeight: UInt32 = 1080,
    runningConfigIDsAfterCommand: [UUID]? = nil,
    managedDisplaysAfterCommand: [DisplayRuntimeManagedVirtualDisplay]? = nil
) -> DisplayRuntimeVirtualDisplayCreateCommandResult {
    let runningConfigIDs = runningConfigIDsAfterCommand ?? createdConfigID.map { [$0] } ?? []
    let managedDisplays: [DisplayRuntimeManagedVirtualDisplay]
    if let managedDisplaysAfterCommand {
        managedDisplays = managedDisplaysAfterCommand
    } else if let createdConfigID, let postDisplayID {
        managedDisplays = [
            DisplayRuntimeManagedVirtualDisplay(
                configID: createdConfigID,
                serialNumber: serialNumber,
                displayID: postDisplayID,
                isLiveRuntime: true
            )
        ]
    } else {
        managedDisplays = []
    }

    return DisplayRuntimeVirtualDisplayCreateCommandResult(
        transactionID: transactionID,
        createdConfigID: createdConfigID,
        serialNumber: serialNumber,
        targetWasRunningAfterCommand: targetWasRunningAfterCommand,
        preDisplayID: preDisplayID,
        postDisplayID: postDisplayID,
        persistenceOutcome: persistenceOutcome,
        runtimeCreationOutcome: runtimeCreationOutcome,
        rollbackOutcome: rollbackOutcome,
        createdConfigEvidence: .init(
            id: createdConfigID,
            serialNumber: serialNumber,
            desiredEnabled: true,
            physicalWidthMillimeters: physicalWidthMillimeters,
            physicalHeightMillimeters: physicalHeightMillimeters,
            modeCount: modeCount,
            maximumPixelWidth: maximumPixelWidth,
            maximumPixelHeight: maximumPixelHeight
        ),
        runningConfigIDsAfterCommand: runningConfigIDs,
        managedDisplaysAfterCommand: managedDisplays
    )
}

func deleteCommandResult(
    transactionID: DisplayRuntimeTransactionID = DisplayRuntimeTransactionID(),
    configID: UUID,
    targetWasRunning: Bool = false,
    preDisplayID: DisplayRuntimeDisplayID? = nil,
    postDisplayID: DisplayRuntimeDisplayID? = nil,
    persistenceOutcome: DisplayRuntimePersistenceOutcome = .saved,
    virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome = .succeeded,
    runtimeTrackingClearOutcome: DisplayRuntimeVirtualDisplayRuntimeTrackingClearOutcome = .cleared,
    runningConfigIDsAfterCommand: [UUID] = [],
    managedDisplaysAfterCommand: [DisplayRuntimeManagedVirtualDisplay] = []
) -> DisplayRuntimeVirtualDisplayDeleteCommandResult {
    DisplayRuntimeVirtualDisplayDeleteCommandResult(
        transactionID: transactionID,
        configID: configID,
        targetWasRunning: targetWasRunning,
        preDisplayID: preDisplayID,
        postDisplayID: postDisplayID,
        persistenceOutcome: persistenceOutcome,
        virtualDisplayCommandOutcome: virtualDisplayCommandOutcome,
        runtimeTrackingClearOutcome: runtimeTrackingClearOutcome,
        runningConfigIDsAfterCommand: runningConfigIDsAfterCommand,
        managedDisplaysAfterCommand: managedDisplaysAfterCommand
    )
}

func rebuildCommandResult(
    configID: UUID,
    preDisplayID: DisplayRuntimeDisplayID? = nil,
    postDisplayID: DisplayRuntimeDisplayID? = nil,
    runningConfigIDsAfterCommand: [UUID]? = nil,
    managedDisplaysAfterCommand: [DisplayRuntimeManagedVirtualDisplay] = []
) -> DisplayRuntimeVirtualDisplayRebuildCommandResult {
    DisplayRuntimeVirtualDisplayRebuildCommandResult(
        configID: configID,
        preDisplayID: preDisplayID,
        postDisplayID: postDisplayID,
        runningConfigIDsAfterCommand: runningConfigIDsAfterCommand ?? [configID],
        managedDisplaysAfterCommand: managedDisplaysAfterCommand
    )
}

func lifecycleCommandResult(
    configID: UUID,
    desiredEnabled: Bool,
    preDisplayID: DisplayRuntimeDisplayID?,
    postDisplayID: DisplayRuntimeDisplayID?,
    runningConfigIDsAfterCommand: [UUID],
    managedDisplaysAfterCommand: [DisplayRuntimeManagedVirtualDisplay] = [],
    mayPerformFleetRebuild: Bool? = nil,
    requiresFleetQuiesce: Bool? = nil
) -> DisplayRuntimeVirtualDisplayLifecycleCommandResult {
    DisplayRuntimeVirtualDisplayLifecycleCommandResult(
        configID: configID,
        desiredEnabled: desiredEnabled,
        preDisplayID: preDisplayID,
        postDisplayID: postDisplayID,
        runningConfigIDsAfterCommand: runningConfigIDsAfterCommand,
        managedDisplaysAfterCommand: managedDisplaysAfterCommand,
        mayPerformFleetRebuild: mayPerformFleetRebuild,
        requiresFleetQuiesce: requiresFleetQuiesce
    )
}

func editRebuildSaveCommandResult(
    previousConfigForCompensation: DisplayRuntimeVirtualDisplayConfigEditDTO,
    savedConfig: DisplayRuntimeVirtualDisplayConfigEditDTO? = nil,
    persistenceOutcome: DisplayRuntimePersistenceOutcome = .saved
) -> DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult {
    let savedConfig = savedConfig ?? previousConfigForCompensation
    return DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult(
        configID: savedConfig.id,
        persistenceOutcome: persistenceOutcome,
        previousConfigForCompensation: previousConfigForCompensation,
        savedConfigEvidence: .init(config: savedConfig)
    )
}

func persistenceCommandResult(
    configID: UUID,
    persistenceOutcome: DisplayRuntimePersistenceOutcome
) -> DisplayRuntimeVirtualDisplayPersistenceCommandResult {
    DisplayRuntimeVirtualDisplayPersistenceCommandResult(
        configID: configID,
        persistenceOutcome: persistenceOutcome
    )
}

func startupRestoreConfig(
    id: UUID,
    serial: UInt32,
    desiredEnabled: Bool = true,
    physicalWidthMillimeters: UInt32 = 600,
    physicalHeightMillimeters: UInt32 = 340,
    modeCount: Int = 1,
    maximumPixelWidth: UInt32 = 1920,
    maximumPixelHeight: UInt32 = 1080
) -> DisplayRuntimeStartupRestoreConfig {
    DisplayRuntimeStartupRestoreConfig(
        id: id,
        desiredEnabled: desiredEnabled,
        evidence: .init(
            id: id,
            serialNumber: serial,
            desiredEnabled: desiredEnabled,
            physicalWidthMillimeters: physicalWidthMillimeters,
            physicalHeightMillimeters: physicalHeightMillimeters,
            modeCount: modeCount,
            maximumPixelWidth: maximumPixelWidth,
            maximumPixelHeight: maximumPixelHeight
        )
    )
}

func startupRestoreCommandResult(
    transactionID: DisplayRuntimeTransactionID = DisplayRuntimeTransactionID(),
    configID: UUID,
    preDisplayID: DisplayRuntimeDisplayID? = nil,
    postDisplayID: DisplayRuntimeDisplayID? = 9001,
    restoreOutcome: DisplayRuntimeVirtualDisplayCommandOutcome = .succeeded,
    didProduceVerifiableSideEffect: Bool = true,
    failureReason: String? = nil,
    compensationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome = .notAttempted,
    compensationFailureReason: String? = nil,
    runningConfigIDsAfterCommand: [UUID]? = nil,
    managedDisplaysAfterCommand: [DisplayRuntimeManagedVirtualDisplay]? = nil
) -> DisplayRuntimeStartupRestoreCommandResult {
    DisplayRuntimeStartupRestoreCommandResult(
        transactionID: transactionID,
        configID: configID,
        preDisplayID: preDisplayID,
        postDisplayID: postDisplayID,
        restoreOutcome: restoreOutcome,
        didProduceVerifiableSideEffect: didProduceVerifiableSideEffect,
        failureReason: failureReason,
        compensationOutcome: compensationOutcome,
        compensationFailureReason: compensationFailureReason,
        runningConfigIDsAfterCommand: runningConfigIDsAfterCommand ?? [configID],
        managedDisplaysAfterCommand: managedDisplaysAfterCommand ?? postDisplayID.map {
            [
                DisplayRuntimeManagedVirtualDisplay(
                    configID: configID,
                    serialNumber: 9001,
                    displayID: $0,
                    isLiveRuntime: true
                )
            ]
        } ?? []
    )
}
