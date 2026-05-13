import Foundation

package nonisolated struct DisplayRuntimeVirtualDisplayRebuildRequest: Codable, Equatable, Sendable {
    package let transactionID: DisplayRuntimeTransactionID
    package let configID: UUID
    package let source: DisplayRuntimeTransactionSource

    package init(
        transactionID: DisplayRuntimeTransactionID = DisplayRuntimeTransactionID(),
        configID: UUID,
        source: DisplayRuntimeTransactionSource
    ) {
        self.transactionID = transactionID
        self.configID = configID
        self.source = source
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayRebuildCommandResult: Codable, Equatable, Sendable {
    package let configID: UUID
    package let preDisplayID: DisplayRuntimeDisplayID?
    package let postDisplayID: DisplayRuntimeDisplayID?
    package let runningConfigIDsAfterCommand: [UUID]
    package let managedDisplaysAfterCommand: [DisplayRuntimeManagedVirtualDisplay]

    package init(
        configID: UUID,
        preDisplayID: DisplayRuntimeDisplayID?,
        postDisplayID: DisplayRuntimeDisplayID?,
        runningConfigIDsAfterCommand: [UUID],
        managedDisplaysAfterCommand: [DisplayRuntimeManagedVirtualDisplay]
    ) {
        self.configID = configID
        self.preDisplayID = preDisplayID
        self.postDisplayID = postDisplayID
        self.runningConfigIDsAfterCommand = runningConfigIDsAfterCommand.sorted { $0.uuidString < $1.uuidString }
        self.managedDisplaysAfterCommand = managedDisplaysAfterCommand.sorted {
            ($0.configID.uuidString, $0.displayID) < ($1.configID.uuidString, $1.displayID)
        }
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayRebuildTransactionResult: Codable, Equatable, Sendable {
    package let transactionID: DisplayRuntimeTransactionID
    package let kind: DisplayRuntimeTransactionKind
    package let status: DisplayRuntimeTransactionStatus
    package let virtualDisplayCommandSucceeded: Bool
    package let hasSessionRecoveryFailures: Bool
    package let desiredEnabled: Bool?

    package init(
        transactionID: DisplayRuntimeTransactionID,
        kind: DisplayRuntimeTransactionKind = .virtualDisplayRebuild,
        status: DisplayRuntimeTransactionStatus,
        virtualDisplayCommandSucceeded: Bool,
        hasSessionRecoveryFailures: Bool,
        desiredEnabled: Bool? = nil
    ) {
        self.transactionID = transactionID
        self.kind = kind
        self.status = status
        self.virtualDisplayCommandSucceeded = virtualDisplayCommandSucceeded
        self.hasSessionRecoveryFailures = hasSessionRecoveryFailures
        self.desiredEnabled = desiredEnabled
    }
}
