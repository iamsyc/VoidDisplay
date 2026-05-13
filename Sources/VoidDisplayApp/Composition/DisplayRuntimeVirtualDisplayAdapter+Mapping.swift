import Foundation
import VoidDisplayFoundation
import VoidDisplayRuntime
import VoidDisplayVirtualDisplay

extension DisplayRuntimeScopeEscalationReason {
    init?(_ reason: VirtualDisplayEnablePreflight.ScopeEscalationReason?) {
        guard let reason else { return nil }
        switch reason {
        case .enableMayPerformFleetRebuild:
            self = .enableMayPerformFleetRebuild
        }
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
            modes: editDTO.modes.map {
                .init(
                    width: $0.width,
                    height: $0.height,
                    refreshRate: $0.refreshRate,
                    enableHiDPI: $0.enableHiDPI
                )
            },
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
            modes: runtimeRequest.modes.map {
                ResolutionSelection(
                    width: $0.width,
                    height: $0.height,
                    refreshRate: $0.refreshRate,
                    enableHiDPI: $0.enableHiDPI
                )
            }
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
            managedDisplaysAfterCommand: lowerResult.managedDisplaysAfterCommand.map(DisplayRuntimeManagedVirtualDisplay.init)
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
            managedDisplaysAfterCommand: lowerResult.managedDisplaysAfterCommand.map(DisplayRuntimeManagedVirtualDisplay.init)
        )
    }
}

private extension DisplayRuntimeManagedVirtualDisplay {
    init(_ display: ManagedVirtualDisplayRuntimeSnapshot) {
        self.init(
            configID: display.configId,
            serialNumber: display.serialNum,
            displayID: display.displayID,
            isLiveRuntime: display.isLiveRuntime
        )
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
            modes: config.modes.map {
                .init(
                    width: $0.width,
                    height: $0.height,
                    refreshRate: $0.refreshRate,
                    enableHiDPI: $0.enableHiDPI
                )
            },
            maximumPixelWidth: maxPixels.width,
            maximumPixelHeight: maxPixels.height
        )
    }
}
