import Foundation

package nonisolated struct DisplayRuntimeTransactionID: Codable, Equatable, Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

package nonisolated enum DisplayRuntimeTransactionKind: String, Codable, Equatable, Hashable, Sendable {
    case virtualDisplayRebuild
    case virtualDisplayEnable
    case virtualDisplayDisable
    case virtualDisplayEditRebuild
    case virtualDisplayCreate
    case virtualDisplayDelete
}

package nonisolated enum DisplayRuntimeTransactionSource: String, Codable, Equatable, Sendable {
    case virtualDisplayRowRetry
    case virtualDisplayRowToggle
    case editSaveAndRebuild
    case createVirtualDisplaySheet
    case deleteVirtualDisplayConfirmation
    case diagnostics
    case unknown
}

package nonisolated enum DisplayRuntimeTransactionPhase: String, Codable, Equatable, Sendable {
    case queued
    case preparing
    case persistingConfig
    case compensatingPersistence
    case quiescingSessions
    case executingVirtualDisplayCommand
    case waitingForTopology
    case restoringSessions
    case completed
    case failed
    case cancelled
}

package nonisolated enum DisplayRuntimeTransactionStatus: String, Codable, Equatable, Sendable {
    case active
    case completed
    case completedWithRecoveryFailures
    case failed
    case cancelled
}

package nonisolated struct DisplayRuntimeTransactionPhaseRecord: Codable, Equatable, Sendable {
    package let phase: DisplayRuntimeTransactionPhase
    package let note: String?

    package init(phase: DisplayRuntimeTransactionPhase, note: String? = nil) {
        self.phase = phase
        self.note = note
    }
}
