import Foundation

package nonisolated struct DisplayRuntimeVirtualDisplayCreateConfigEvidence: Codable, Equatable, Sendable {
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

package nonisolated struct DisplayRuntimeVirtualDisplayCreateRequest: Codable, Equatable, Sendable {
    package let transactionID: DisplayRuntimeTransactionID
    package let displayName: String
    package let serialNumber: UInt32
    package let physicalWidthMillimeters: UInt32
    package let physicalHeightMillimeters: UInt32
    package let maximumPixelWidth: UInt32
    package let maximumPixelHeight: UInt32
    package let modes: [DisplayRuntimeVirtualDisplayModeDTO]
    package let source: DisplayRuntimeTransactionSource

    package init(
        transactionID: DisplayRuntimeTransactionID = DisplayRuntimeTransactionID(),
        displayName: String,
        serialNumber: UInt32,
        physicalWidthMillimeters: UInt32,
        physicalHeightMillimeters: UInt32,
        maximumPixelWidth: UInt32,
        maximumPixelHeight: UInt32,
        modes: [DisplayRuntimeVirtualDisplayModeDTO],
        source: DisplayRuntimeTransactionSource
    ) {
        self.transactionID = transactionID
        self.displayName = displayName
        self.serialNumber = serialNumber
        self.physicalWidthMillimeters = physicalWidthMillimeters
        self.physicalHeightMillimeters = physicalHeightMillimeters
        self.maximumPixelWidth = maximumPixelWidth
        self.maximumPixelHeight = maximumPixelHeight
        self.modes = modes
        self.source = source
    }

    package var redactedEvidence: DisplayRuntimeVirtualDisplayCreateConfigEvidence {
        DisplayRuntimeVirtualDisplayCreateConfigEvidence(
            id: nil,
            serialNumber: serialNumber,
            desiredEnabled: true,
            physicalWidthMillimeters: physicalWidthMillimeters,
            physicalHeightMillimeters: physicalHeightMillimeters,
            modeCount: modes.count,
            maximumPixelWidth: maximumPixelWidth,
            maximumPixelHeight: maximumPixelHeight
        )
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayCreateCommandResult: Codable, Equatable, Sendable {
    package let transactionID: DisplayRuntimeTransactionID
    package let createdConfigID: UUID?
    package let serialNumber: UInt32
    package let targetWasRunningAfterCommand: Bool
    package let preDisplayID: DisplayRuntimeDisplayID?
    package let postDisplayID: DisplayRuntimeDisplayID?
    package let persistenceOutcome: DisplayRuntimePersistenceOutcome
    package let runtimeCreationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome
    package let rollbackOutcome: DisplayRuntimePersistenceOutcome
    package let createdConfigEvidence: DisplayRuntimeVirtualDisplayCreateConfigEvidence
    package let runningConfigIDsAfterCommand: [UUID]
    package let managedDisplaysAfterCommand: [DisplayRuntimeManagedVirtualDisplay]

    package init(
        transactionID: DisplayRuntimeTransactionID,
        createdConfigID: UUID?,
        serialNumber: UInt32,
        targetWasRunningAfterCommand: Bool,
        preDisplayID: DisplayRuntimeDisplayID?,
        postDisplayID: DisplayRuntimeDisplayID?,
        persistenceOutcome: DisplayRuntimePersistenceOutcome,
        runtimeCreationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome,
        rollbackOutcome: DisplayRuntimePersistenceOutcome,
        createdConfigEvidence: DisplayRuntimeVirtualDisplayCreateConfigEvidence,
        runningConfigIDsAfterCommand: [UUID],
        managedDisplaysAfterCommand: [DisplayRuntimeManagedVirtualDisplay]
    ) {
        self.transactionID = transactionID
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
            ($0.configID.uuidString, $0.displayID) < ($1.configID.uuidString, $1.displayID)
        }
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayCreateCommandError: Error, Sendable {
    package let reason: String
    package let result: DisplayRuntimeVirtualDisplayCreateCommandResult

    package init(reason: String, result: DisplayRuntimeVirtualDisplayCreateCommandResult) {
        self.reason = reason
        self.result = result
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayCreateTransactionResult: Codable, Equatable, Sendable {
    package let transactionID: DisplayRuntimeTransactionID
    package let status: DisplayRuntimeTransactionStatus
    package let createdConfigID: UUID?
    package let serialNumber: UInt32
    package let persistenceOutcome: DisplayRuntimePersistenceOutcome
    package let runtimeCreationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome
    package let rollbackOutcome: DisplayRuntimePersistenceOutcome
    package let topologyStabilityResult: DisplayRuntimeTopologyStabilityResult?
    package let hasRecoveryFailures: Bool

    package init(
        transactionID: DisplayRuntimeTransactionID,
        status: DisplayRuntimeTransactionStatus,
        createdConfigID: UUID?,
        serialNumber: UInt32,
        persistenceOutcome: DisplayRuntimePersistenceOutcome,
        runtimeCreationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome,
        rollbackOutcome: DisplayRuntimePersistenceOutcome,
        topologyStabilityResult: DisplayRuntimeTopologyStabilityResult?,
        hasRecoveryFailures: Bool
    ) {
        self.transactionID = transactionID
        self.status = status
        self.createdConfigID = createdConfigID
        self.serialNumber = serialNumber
        self.persistenceOutcome = persistenceOutcome
        self.runtimeCreationOutcome = runtimeCreationOutcome
        self.rollbackOutcome = rollbackOutcome
        self.topologyStabilityResult = topologyStabilityResult
        self.hasRecoveryFailures = hasRecoveryFailures
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayDeleteCommandRequest: Codable, Equatable, Sendable {
    package let transactionID: DisplayRuntimeTransactionID
    package let configID: UUID
    package let targetPreDisplayID: DisplayRuntimeDisplayID?
    package let targetWasRunning: Bool

    package init(
        transactionID: DisplayRuntimeTransactionID,
        configID: UUID,
        targetPreDisplayID: DisplayRuntimeDisplayID?,
        targetWasRunning: Bool
    ) {
        self.transactionID = transactionID
        self.configID = configID
        self.targetPreDisplayID = targetPreDisplayID
        self.targetWasRunning = targetWasRunning
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayDeleteCommandResult: Codable, Equatable, Sendable {
    package let transactionID: DisplayRuntimeTransactionID
    package let configID: UUID
    package let targetWasRunning: Bool
    package let preDisplayID: DisplayRuntimeDisplayID?
    package let postDisplayID: DisplayRuntimeDisplayID?
    package let persistenceOutcome: DisplayRuntimePersistenceOutcome
    package let virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome
    package let runtimeTrackingClearOutcome: DisplayRuntimeVirtualDisplayRuntimeTrackingClearOutcome
    package let runningConfigIDsAfterCommand: [UUID]
    package let managedDisplaysAfterCommand: [DisplayRuntimeManagedVirtualDisplay]

    package init(
        transactionID: DisplayRuntimeTransactionID,
        configID: UUID,
        targetWasRunning: Bool,
        preDisplayID: DisplayRuntimeDisplayID?,
        postDisplayID: DisplayRuntimeDisplayID?,
        persistenceOutcome: DisplayRuntimePersistenceOutcome,
        virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome,
        runtimeTrackingClearOutcome: DisplayRuntimeVirtualDisplayRuntimeTrackingClearOutcome,
        runningConfigIDsAfterCommand: [UUID],
        managedDisplaysAfterCommand: [DisplayRuntimeManagedVirtualDisplay]
    ) {
        self.transactionID = transactionID
        self.configID = configID
        self.targetWasRunning = targetWasRunning
        self.preDisplayID = preDisplayID
        self.postDisplayID = postDisplayID
        self.persistenceOutcome = persistenceOutcome
        self.virtualDisplayCommandOutcome = virtualDisplayCommandOutcome
        self.runtimeTrackingClearOutcome = runtimeTrackingClearOutcome
        self.runningConfigIDsAfterCommand = runningConfigIDsAfterCommand.sorted { $0.uuidString < $1.uuidString }
        self.managedDisplaysAfterCommand = managedDisplaysAfterCommand.sorted {
            ($0.configID.uuidString, $0.displayID) < ($1.configID.uuidString, $1.displayID)
        }
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayDeleteCommandError: Error, Sendable {
    package let reason: String
    package let result: DisplayRuntimeVirtualDisplayDeleteCommandResult

    package init(reason: String, result: DisplayRuntimeVirtualDisplayDeleteCommandResult) {
        self.reason = reason
        self.result = result
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayDeleteTransactionResult: Codable, Equatable, Sendable {
    package let transactionID: DisplayRuntimeTransactionID
    package let status: DisplayRuntimeTransactionStatus
    package let configID: UUID
    package let targetWasRunning: Bool
    package let persistenceOutcome: DisplayRuntimePersistenceOutcome
    package let virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome
    package let runtimeTrackingClearOutcome: DisplayRuntimeVirtualDisplayRuntimeTrackingClearOutcome
    package let topologyStabilityResult: DisplayRuntimeTopologyStabilityResult?
    package let hasRecoveryFailures: Bool

    package init(
        transactionID: DisplayRuntimeTransactionID,
        status: DisplayRuntimeTransactionStatus,
        configID: UUID,
        targetWasRunning: Bool,
        persistenceOutcome: DisplayRuntimePersistenceOutcome,
        virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome,
        runtimeTrackingClearOutcome: DisplayRuntimeVirtualDisplayRuntimeTrackingClearOutcome,
        topologyStabilityResult: DisplayRuntimeTopologyStabilityResult?,
        hasRecoveryFailures: Bool
    ) {
        self.transactionID = transactionID
        self.status = status
        self.configID = configID
        self.targetWasRunning = targetWasRunning
        self.persistenceOutcome = persistenceOutcome
        self.virtualDisplayCommandOutcome = virtualDisplayCommandOutcome
        self.runtimeTrackingClearOutcome = runtimeTrackingClearOutcome
        self.topologyStabilityResult = topologyStabilityResult
        self.hasRecoveryFailures = hasRecoveryFailures
    }
}
