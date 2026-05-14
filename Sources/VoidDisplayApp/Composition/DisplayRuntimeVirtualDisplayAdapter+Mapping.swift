import Foundation
import VoidDisplayFoundation
import VoidDisplayRuntime
import VoidDisplayVirtualDisplay

extension DisplayRuntimeTransactionSource {
    init(_ source: VirtualDisplayRebuildRequestSource) {
        switch source {
        case .rowRetry:
            self = .virtualDisplayRowRetry
        case .editSaveAndRebuild:
            self = .editSaveAndRebuild
        case .unknown:
            self = .unknown
        }
    }

    init(_ source: VirtualDisplayDesiredEnabledRequestSource) {
        switch source {
        case .rowToggle:
            self = .virtualDisplayRowToggle
        case .unknown:
            self = .unknown
        }
    }
}

extension VirtualDisplayEditRebuildTransactionStatus {
    init(_ status: DisplayRuntimeTransactionStatus) {
        switch status {
        case .completed:
            self = .completed
        case .completedWithRecoveryFailures:
            self = .completedWithRecoveryFailures
        case .failed:
            self = .failed
        case .cancelled:
            self = .cancelled
        case .active:
            self = .failed
        }
    }
}

extension VirtualDisplayCommandTransactionStatus {
    init(_ status: DisplayRuntimeTransactionStatus) {
        switch status {
        case .completed:
            self = .completed
        case .completedWithRecoveryFailures:
            self = .completedWithRecoveryFailures
        case .failed:
            self = .failed
        case .cancelled:
            self = .cancelled
        case .active:
            self = .failed
        }
    }
}

extension DisplayRuntimeScopeEscalationReason {
    init?(_ reason: VirtualDisplayEnablePreflight.ScopeEscalationReason?) {
        guard let reason else { return nil }
        switch reason {
        case .enableMayPerformFleetRebuild:
            self = .enableMayPerformFleetRebuild
        }
    }
}

extension DisplayRuntimeVirtualDisplaySnapshot {
    @MainActor
    init(
        adapterController controller: VirtualDisplayController
    ) {
        self.init(
            rebuildRequestCount: controller.rebuildRequestCount,
            rebuildingConfigIDs: Array(controller.rebuildingConfigIds),
            runningConfigIDs: Array(controller.runningConfigIds),
            recentlyAppliedConfigIDs: Array(controller.recentlyAppliedConfigIds),
            rebuildFailureConfigIDs: Array(controller.rebuildFailureMessageByConfigId.keys),
            configStoreHasLoadFailure: controller.configStorePresentation.hasLoadFailure,
            configStoreHasDiagnostics: controller.configStorePresentation.loadErrorMessage != nil
                || controller.configStorePresentation.diagnosticsSummary != nil,
            managedDisplays: controller.managedDisplays.displayRuntimeManagedDisplays,
            configs: controller.displayConfigs.displayRuntimeVirtualDisplayConfigs,
            restoreFailureConfigIDs: controller.restoreFailures.map(\.id)
        )
    }
}

extension VirtualDisplayConfig {
    init(editDTO: DisplayRuntimeVirtualDisplayConfigEditDTO) {
        self.init(
            id: editDTO.id,
            displayName: editDTO.displayName,
            serialNum: editDTO.serialNumber,
            physicalWidth: Int(editDTO.physicalWidthMillimeters),
            physicalHeight: Int(editDTO.physicalHeightMillimeters),
            modes: editDTO.modes.adapterModeConfigs,
            desiredEnabled: editDTO.desiredEnabled
        )
    }
}

extension VirtualDisplayCreateRequest {
    init(runtimeRequest: DisplayRuntimeVirtualDisplayCreateRequest) {
        self.init(
            displayName: runtimeRequest.displayName,
            serialNumber: runtimeRequest.serialNumber,
            physicalWidthMillimeters: runtimeRequest.physicalWidthMillimeters,
            physicalHeightMillimeters: runtimeRequest.physicalHeightMillimeters,
            maximumPixelWidth: runtimeRequest.maximumPixelWidth,
            maximumPixelHeight: runtimeRequest.maximumPixelHeight,
            modes: runtimeRequest.modes.resolutionSelections
        )
    }
}

extension DisplayRuntimeVirtualDisplayCreateRequest {
    init(request: VirtualDisplayCreateRequest, source: DisplayRuntimeTransactionSource) {
        self.init(
            displayName: request.displayName,
            serialNumber: request.serialNumber,
            physicalWidthMillimeters: request.physicalWidthMillimeters,
            physicalHeightMillimeters: request.physicalHeightMillimeters,
            maximumPixelWidth: request.maximumPixelWidth,
            maximumPixelHeight: request.maximumPixelHeight,
            modes: request.modes.displayRuntimeModeDTOs,
            source: source
        )
    }
}

extension DisplayRuntimeVirtualDisplayRebuildCommandResult {
    init(
        configID: UUID,
        preDisplayID: DisplayRuntimeDisplayID?,
        postDisplayID: DisplayRuntimeDisplayID?,
        runningConfigIDsAfterCommand: Set<UUID>,
        managedDisplaysAfterCommand: [ManagedVirtualDisplayRuntimeSnapshot]
    ) {
        self.init(
            configID: configID,
            preDisplayID: preDisplayID,
            postDisplayID: postDisplayID,
            runningConfigIDsAfterCommand: Array(runningConfigIDsAfterCommand),
            managedDisplaysAfterCommand: managedDisplaysAfterCommand.displayRuntimeManagedDisplays
        )
    }
}

extension DisplayRuntimeVirtualDisplayLifecycleCommandResult {
    init(
        lowerResult: VirtualDisplayLifecycleCommandResult,
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest,
        runningConfigIDsAfterCommand: Set<UUID>,
        managedDisplaysAfterCommand: [ManagedVirtualDisplayRuntimeSnapshot]
    ) {
        self.init(
            configID: lowerResult.configID,
            desiredEnabled: lowerResult.desiredEnabled,
            preDisplayID: lowerResult.preDisplayID ?? request.targetPreDisplayID,
            postDisplayID: lowerResult.postDisplayID,
            runningConfigIDsAfterCommand: Array(runningConfigIDsAfterCommand),
            managedDisplaysAfterCommand: managedDisplaysAfterCommand.displayRuntimeManagedDisplays,
            mayPerformFleetRebuild: lowerResult.mayPerformFleetRebuild,
            requiresFleetQuiesce: lowerResult.requiresFleetQuiesce
        )
    }
}

extension DisplayRuntimeVirtualDisplayCreateCommandResult {
    init(
        transactionID: DisplayRuntimeTransactionID,
        lowerResult: VirtualDisplayCreateCommandResult
    ) {
        self.init(
            transactionID: transactionID,
            createdConfigID: lowerResult.createdConfigID,
            serialNumber: lowerResult.serialNumber,
            targetWasRunningAfterCommand: lowerResult.targetWasRunningAfterCommand,
            preDisplayID: lowerResult.preDisplayID,
            postDisplayID: lowerResult.postDisplayID,
            persistenceOutcome: DisplayRuntimePersistenceOutcome(lowerResult.persistenceOutcome),
            runtimeCreationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome(lowerResult.runtimeCreationOutcome),
            rollbackOutcome: DisplayRuntimePersistenceOutcome(lowerResult.rollbackOutcome),
            createdConfigEvidence: DisplayRuntimeVirtualDisplayCreateConfigEvidence(lowerResult.createdConfigEvidence),
            runningConfigIDsAfterCommand: lowerResult.runningConfigIDsAfterCommand,
            managedDisplaysAfterCommand: lowerResult.managedDisplaysAfterCommand.displayRuntimeManagedDisplays
        )
    }
}

extension DisplayRuntimeVirtualDisplayDeleteCommandResult {
    init(
        transactionID: DisplayRuntimeTransactionID,
        lowerResult: VirtualDisplayDeleteCommandResult
    ) {
        self.init(
            transactionID: transactionID,
            configID: lowerResult.configID,
            targetWasRunning: lowerResult.targetWasRunning,
            preDisplayID: lowerResult.preDisplayID,
            postDisplayID: lowerResult.postDisplayID,
            persistenceOutcome: DisplayRuntimePersistenceOutcome(lowerResult.persistenceOutcome),
            virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome(lowerResult.virtualDisplayCommandOutcome),
            runtimeTrackingClearOutcome: DisplayRuntimeVirtualDisplayRuntimeTrackingClearOutcome(lowerResult.runtimeTrackingClearOutcome),
            runningConfigIDsAfterCommand: lowerResult.runningConfigIDsAfterCommand,
            managedDisplaysAfterCommand: lowerResult.managedDisplaysAfterCommand.displayRuntimeManagedDisplays
        )
    }
}

private extension DisplayRuntimeManagedVirtualDisplay {
    init(adapterManagedDisplay display: ManagedVirtualDisplayRuntimeSnapshot) {
        self.init(
            configID: display.configId,
            serialNumber: display.serialNum,
            displayID: display.displayID,
            isLiveRuntime: display.isLiveRuntime
        )
    }
}

private extension DisplayRuntimeVirtualDisplayConfig {
    init(adapterConfig config: VirtualDisplayConfig) {
        self.init(
            id: config.id,
            serialNumber: config.serialNum,
            desiredEnabled: config.desiredEnabled,
            physicalWidthMillimeters: config.physicalWidth,
            physicalHeightMillimeters: config.physicalHeight,
            modes: config.modes.displayRuntimeModes
        )
    }
}

private extension DisplayRuntimeVirtualDisplayMode {
    init(adapterMode mode: VirtualDisplayConfig.ModeConfig) {
        self.init(
            width: mode.width,
            height: mode.height,
            refreshRate: mode.refreshRate,
            enableHiDPI: mode.enableHiDPI
        )
    }
}

private extension DisplayRuntimeVirtualDisplayModeDTO {
    init(adapterMode mode: VirtualDisplayConfig.ModeConfig) {
        self.init(
            width: mode.width,
            height: mode.height,
            refreshRate: mode.refreshRate,
            enableHiDPI: mode.enableHiDPI
        )
    }

    init(resolutionSelection mode: ResolutionSelection) {
        self.init(
            width: mode.width,
            height: mode.height,
            refreshRate: mode.refreshRate,
            enableHiDPI: mode.enableHiDPI
        )
    }
}

private extension VirtualDisplayConfig.ModeConfig {
    init(runtimeMode mode: DisplayRuntimeVirtualDisplayModeDTO) {
        self.init(
            width: mode.width,
            height: mode.height,
            refreshRate: mode.refreshRate,
            enableHiDPI: mode.enableHiDPI
        )
    }
}

private extension ResolutionSelection {
    init(runtimeMode mode: DisplayRuntimeVirtualDisplayModeDTO) {
        self.init(
            width: mode.width,
            height: mode.height,
            refreshRate: mode.refreshRate,
            enableHiDPI: mode.enableHiDPI
        )
    }
}

private extension Array where Element == ManagedVirtualDisplayRuntimeSnapshot {
    var displayRuntimeManagedDisplays: [DisplayRuntimeManagedVirtualDisplay] {
        map { DisplayRuntimeManagedVirtualDisplay(adapterManagedDisplay: $0) }
    }
}

private extension Array where Element == VirtualDisplayConfig {
    var displayRuntimeVirtualDisplayConfigs: [DisplayRuntimeVirtualDisplayConfig] {
        map { DisplayRuntimeVirtualDisplayConfig(adapterConfig: $0) }
    }
}

private extension Array where Element == VirtualDisplayConfig.ModeConfig {
    var displayRuntimeModes: [DisplayRuntimeVirtualDisplayMode] {
        map { DisplayRuntimeVirtualDisplayMode(adapterMode: $0) }
    }

    var displayRuntimeModeDTOs: [DisplayRuntimeVirtualDisplayModeDTO] {
        map { DisplayRuntimeVirtualDisplayModeDTO(adapterMode: $0) }
    }
}

private extension Array where Element == DisplayRuntimeVirtualDisplayModeDTO {
    var adapterModeConfigs: [VirtualDisplayConfig.ModeConfig] {
        map { VirtualDisplayConfig.ModeConfig(runtimeMode: $0) }
    }

    var resolutionSelections: [ResolutionSelection] {
        map { ResolutionSelection(runtimeMode: $0) }
    }
}

private extension Array where Element == ResolutionSelection {
    var displayRuntimeModeDTOs: [DisplayRuntimeVirtualDisplayModeDTO] {
        map { DisplayRuntimeVirtualDisplayModeDTO(resolutionSelection: $0) }
    }
}

private extension DisplayRuntimeVirtualDisplayCreateConfigEvidence {
    init(_ evidence: VirtualDisplayCommandConfigEvidence) {
        self.init(
            id: evidence.id,
            serialNumber: evidence.serialNumber,
            desiredEnabled: evidence.desiredEnabled,
            physicalWidthMillimeters: evidence.physicalWidthMillimeters,
            physicalHeightMillimeters: evidence.physicalHeightMillimeters,
            modeCount: evidence.modeCount,
            maximumPixelWidth: evidence.maximumPixelWidth,
            maximumPixelHeight: evidence.maximumPixelHeight
        )
    }
}

private extension DisplayRuntimePersistenceOutcome {
    init(_ outcome: VirtualDisplayCommandPersistenceOutcome) {
        switch outcome {
        case .notAttempted:
            self = .notAttempted
        case .saved:
            self = .saved
        case .failed:
            self = .failed
        case .rolledBack:
            self = .rolledBack
        case .rollbackFailed:
            self = .rollbackFailed
        }
    }
}

private extension DisplayRuntimeVirtualDisplayCommandOutcome {
    init(_ outcome: VirtualDisplayCommandRuntimeOutcome) {
        switch outcome {
        case .notAttempted:
            self = .notAttempted
        case .succeeded:
            self = .succeeded
        case .failed:
            self = .failed
        }
    }
}

private extension DisplayRuntimeVirtualDisplayRuntimeTrackingClearOutcome {
    init(_ outcome: VirtualDisplayRuntimeTrackingClearOutcome) {
        switch outcome {
        case .notAttempted:
            self = .notAttempted
        case .cleared:
            self = .cleared
        case .failed:
            self = .failed
        }
    }
}

extension DisplayRuntimeVirtualDisplayConfigEditDTO {
    init(adapterConfig config: VirtualDisplayConfig) {
        let maxPixels = config.maxPixelDimensions
        self.init(
            id: config.id,
            displayName: config.displayName,
            serialNumber: config.serialNum,
            desiredEnabled: config.desiredEnabled,
            physicalWidthMillimeters: UInt32(clamping: config.physicalWidth),
            physicalHeightMillimeters: UInt32(clamping: config.physicalHeight),
            modes: config.modes.displayRuntimeModeDTOs,
            maximumPixelWidth: maxPixels.width,
            maximumPixelHeight: maxPixels.height
        )
    }
}
