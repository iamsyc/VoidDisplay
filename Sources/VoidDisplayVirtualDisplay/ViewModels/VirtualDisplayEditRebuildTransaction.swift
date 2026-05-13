import Foundation
import VoidDisplayFoundation

package enum VirtualDisplayEditRebuildTransactionStatus: Equatable, Sendable {
    case completed
    case completedWithRecoveryFailures
    case failed
    case cancelled
}

package enum VirtualDisplayCommandTransactionStatus: Equatable, Sendable {
    case completed
    case completedWithRecoveryFailures
    case failed
    case cancelled
}

package struct VirtualDisplayCreateRequest: Equatable, Sendable {
    package let displayName: String
    package let serialNumber: UInt32
    package let physicalWidthMillimeters: UInt32
    package let physicalHeightMillimeters: UInt32
    package let maximumPixelWidth: UInt32
    package let maximumPixelHeight: UInt32
    package let modes: [ResolutionSelection]

    package init(
        displayName: String,
        serialNumber: UInt32,
        physicalWidthMillimeters: UInt32,
        physicalHeightMillimeters: UInt32,
        maximumPixelWidth: UInt32,
        maximumPixelHeight: UInt32,
        modes: [ResolutionSelection]
    ) {
        self.displayName = displayName
        self.serialNumber = serialNumber
        self.physicalWidthMillimeters = physicalWidthMillimeters
        self.physicalHeightMillimeters = physicalHeightMillimeters
        self.maximumPixelWidth = maximumPixelWidth
        self.maximumPixelHeight = maximumPixelHeight
        self.modes = modes
    }
}

package struct VirtualDisplayCreateTransactionResult: Equatable, Sendable {
    package let transactionID: UUID
    package let status: VirtualDisplayCommandTransactionStatus
    package let createdConfigID: UUID?
    package let virtualDisplayCommandSucceeded: Bool

    package init(
        transactionID: UUID,
        status: VirtualDisplayCommandTransactionStatus,
        createdConfigID: UUID?,
        virtualDisplayCommandSucceeded: Bool
    ) {
        self.transactionID = transactionID
        self.status = status
        self.createdConfigID = createdConfigID
        self.virtualDisplayCommandSucceeded = virtualDisplayCommandSucceeded
    }
}

package struct VirtualDisplayDeleteTransactionResult: Equatable, Sendable {
    package let transactionID: UUID
    package let status: VirtualDisplayCommandTransactionStatus
    package let configID: UUID
    package let virtualDisplayCommandSucceeded: Bool

    package init(
        transactionID: UUID,
        status: VirtualDisplayCommandTransactionStatus,
        configID: UUID,
        virtualDisplayCommandSucceeded: Bool
    ) {
        self.transactionID = transactionID
        self.status = status
        self.configID = configID
        self.virtualDisplayCommandSucceeded = virtualDisplayCommandSucceeded
    }
}

package struct VirtualDisplayEditRebuildSaveGateResult: Equatable, Sendable {
    package let transactionID: UUID
    package let configID: UUID

    package init(transactionID: UUID, configID: UUID) {
        self.transactionID = transactionID
        self.configID = configID
    }
}

package struct VirtualDisplayEditRebuildTransactionResult: Equatable, Sendable {
    package let transactionID: UUID
    package let status: VirtualDisplayEditRebuildTransactionStatus
    package let virtualDisplayCommandSucceeded: Bool

    package init(
        transactionID: UUID,
        status: VirtualDisplayEditRebuildTransactionStatus,
        virtualDisplayCommandSucceeded: Bool
    ) {
        self.transactionID = transactionID
        self.status = status
        self.virtualDisplayCommandSucceeded = virtualDisplayCommandSucceeded
    }
}

package struct VirtualDisplayEditRebuildTransactionHandle: Sendable {
    package let transactionID: UUID
    private let saveGateTask: Task<VirtualDisplayEditRebuildSaveGateResult, any Error>
    private let terminalResultTask: Task<VirtualDisplayEditRebuildTransactionResult, any Error>

    package init(
        transactionID: UUID,
        saveGateTask: Task<VirtualDisplayEditRebuildSaveGateResult, any Error>,
        terminalResultTask: Task<VirtualDisplayEditRebuildTransactionResult, any Error>
    ) {
        self.transactionID = transactionID
        self.saveGateTask = saveGateTask
        self.terminalResultTask = terminalResultTask
    }

    package func waitForSaveGate() async throws -> VirtualDisplayEditRebuildSaveGateResult {
        try await saveGateTask.value
    }

    package func waitForTerminalResult() async throws -> VirtualDisplayEditRebuildTransactionResult {
        try await terminalResultTask.value
    }
}
