import Foundation

package enum VirtualDisplayEditRebuildTransactionStatus: Equatable, Sendable {
    case completed
    case completedWithRecoveryFailures
    case failed
    case cancelled
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
