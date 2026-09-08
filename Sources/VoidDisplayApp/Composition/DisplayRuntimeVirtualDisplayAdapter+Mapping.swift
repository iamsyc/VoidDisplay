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
    init(commandSnapshot: VirtualDisplaySnapshot) {
        self.init(
            runningConfigIDs: Array(commandSnapshot.runningConfigIds),
            configStoreHasLoadFailure: commandSnapshot.configStorePresentation.hasLoadFailure,
            configStoreHasDiagnostics: commandSnapshot.configStorePresentation.loadErrorMessage != nil
                || commandSnapshot.configStorePresentation.diagnosticsSummary != nil,
            managedDisplays: commandSnapshot.managedDisplays.displayRuntimeManagedDisplays,
            configs: commandSnapshot.configs.displayRuntimeVirtualDisplayConfigs,
            restoreFailureConfigIDs: commandSnapshot.restoreFailures.map(\.id)
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

extension DisplayRuntimeVirtualDisplayLifecycleCommandResult {
    init(
        lowerResult: VirtualDisplayLifecycleCommandResult,
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) {
        self.init(
            configID: lowerResult.configID,
            desiredEnabled: lowerResult.desiredEnabled,
            preDisplayID: lowerResult.preDisplayID ?? request.targetPreDisplayID,
            postDisplayID: lowerResult.postDisplayID,
            mayPerformFleetRebuild: lowerResult.mayPerformFleetRebuild,
            requiresFleetQuiesce: lowerResult.requiresFleetQuiesce
        )
    }
}

extension DisplayRuntimeVirtualDisplayCreateCommandResult {
    init(
        transactionID: DisplayRuntimeTransactionID,
        lowerResult: VirtualDisplayCreateCommandResult,
        request: DisplayRuntimeVirtualDisplayCreateRequest
    ) {
        self.init(
            transactionID: transactionID,
            createdConfigID: lowerResult.createdConfigID,
            serialNumber: request.serialNumber,
            persistenceOutcome: DisplayRuntimePersistenceOutcome(lowerResult.persistenceOutcome),
            runtimeCreationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome(lowerResult.runtimeCreationOutcome),
            rollbackOutcome: DisplayRuntimePersistenceOutcome(lowerResult.rollbackOutcome),
            createdConfigEvidence: DisplayRuntimeVirtualDisplayCreateConfigEvidence(request: request, configID: lowerResult.createdConfigID)
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
            runtimeTrackingClearOutcome: DisplayRuntimeVirtualDisplayRuntimeTrackingClearOutcome(lowerResult.runtimeTrackingClearOutcome)
        )
    }
}

extension DisplayRuntimeStartupRestoreConfigLoadResult {
    init(lowerResult: VirtualDisplayStartupRestoreConfigLoadResult) {
        self.init(
            status: DisplayRuntimeStartupRestoreConfigLoadStatus(lowerResult.status),
            configs: lowerResult.configs.map(DisplayRuntimeStartupRestoreConfig.init(lowerConfig:)),
            failureReason: lowerResult.failureReason,
            underlyingDomain: lowerResult.underlyingDomain,
            underlyingCode: lowerResult.underlyingCode
        )
    }
}

extension DisplayRuntimeStartupRestoreConfig {
    init(lowerConfig config: VirtualDisplayConfig) {
        self.init(
            id: config.id,
            desiredEnabled: config.desiredEnabled,
            evidence: DisplayRuntimeVirtualDisplayConfigEvidence(adapterConfig: config)
        )
    }
}

extension VirtualDisplayStartupRestoreCommandRequest {
    init(runtimeRequest request: DisplayRuntimeStartupRestoreCommandRequest) {
        self.init(
            transactionID: request.transactionID.rawValue,
            runID: request.runID.rawValue,
            configID: request.configID
        )
    }
}

extension DisplayRuntimeStartupRestoreCommandResult {
    init(
        runtimeRequest request: DisplayRuntimeStartupRestoreCommandRequest,
        lowerResult: VirtualDisplayStartupRestoreCommandResult
    ) {
        self.init(
            transactionID: request.transactionID,
            configID: lowerResult.configID,
            preDisplayID: lowerResult.preDisplayID,
            postDisplayID: lowerResult.postDisplayID,
            restoreOutcome: DisplayRuntimeVirtualDisplayCommandOutcome(lowerResult.restoreOutcome),
            didProduceVerifiableSideEffect: lowerResult.didProduceVerifiableSideEffect,
            failureReason: lowerResult.failureReason,
            underlyingDomain: lowerResult.underlyingDomain,
            underlyingCode: lowerResult.underlyingCode,
            compensationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome(lowerResult.compensationOutcome),
            compensationFailureReason: lowerResult.compensationFailureReason
        )
    }
}

private extension DisplayRuntimeStartupRestoreConfigLoadStatus {
    init(_ status: VirtualDisplayStartupRestoreConfigLoadStatus) {
        switch status {
        case .succeeded:
            self = .succeeded
        case .failed:
            self = .failed
        }
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
        let maxPixels = config.maxPixelDimensions
        self.init(
            id: config.id,
            serialNumber: config.serialNum,
            desiredEnabled: config.desiredEnabled,
            physicalWidthMillimeters: config.physicalWidth,
            physicalHeightMillimeters: config.physicalHeight,
            modes: config.modes.displayRuntimeModes,
            maximumPixelWidth: maxPixels.width,
            maximumPixelHeight: maxPixels.height
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

extension Array where Element == DisplayRuntimeVirtualDisplayModeDTO {
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
    init(request: DisplayRuntimeVirtualDisplayCreateRequest, configID: UUID?) {
        self.init(
            id: configID,
            serialNumber: request.serialNumber,
            desiredEnabled: true,
            physicalWidthMillimeters: request.physicalWidthMillimeters,
            physicalHeightMillimeters: request.physicalHeightMillimeters,
            modeCount: request.modes.count,
            maximumPixelWidth: request.maximumPixelWidth,
            maximumPixelHeight: request.maximumPixelHeight
        )
    }
}

private extension DisplayRuntimeVirtualDisplayConfigEvidence {
    init(adapterConfig config: VirtualDisplayConfig) {
        let maxPixels = config.maxPixelDimensions
        self.init(
            id: config.id,
            serialNumber: config.serialNum,
            desiredEnabled: config.desiredEnabled,
            physicalWidthMillimeters: UInt32(clamping: config.physicalWidth),
            physicalHeightMillimeters: UInt32(clamping: config.physicalHeight),
            modeCount: config.modes.count,
            maximumPixelWidth: maxPixels.width,
            maximumPixelHeight: maxPixels.height
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
    init(_ outcome: VirtualDisplayStartupRestoreCommandOutcome) {
        switch outcome {
        case .notAttempted:
            self = .notAttempted
        case .succeeded:
            self = .succeeded
        case .failed:
            self = .failed
        case .invalidated:
            self = .invalidated
        case .partiallySucceeded:
            self = .partiallySucceeded
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
