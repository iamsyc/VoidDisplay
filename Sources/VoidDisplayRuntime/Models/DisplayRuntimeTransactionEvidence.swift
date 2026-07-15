import Foundation

package nonisolated enum DisplayRuntimeAffectedSurfaceReason: String, Codable, Equatable, Sendable {
    case requestedConfig
    case managedMainFleetPeer
    case enableFleetRiskPeer
}

package nonisolated enum DisplayRuntimeScopeEscalationReason: String, Codable, Equatable, Sendable {
    case targetDisabled
    case managedMainPolicyRisk
    case enableMayPerformFleetRebuild
    case scopeEscalatedEnableMayPerformFleetRebuild
}

package nonisolated enum DisplayRuntimePersistenceOutcome: String, Codable, Equatable, Sendable {
    case notAttempted
    case saved
    case failed
    case rolledBack
    case rollbackFailed
}

package nonisolated enum DisplayRuntimeVirtualDisplayCommandOutcome: String, Codable, Equatable, Sendable {
    case notAttempted
    case succeeded
    case failed
    case invalidated
    case partiallySucceeded
}

package nonisolated enum DisplayRuntimeVirtualDisplayRuntimeTrackingClearOutcome: String, Codable, Equatable, Sendable {
    case notAttempted
    case cleared
    case failed
}

package nonisolated struct DisplayRuntimeAffectedSurface: Codable, Equatable, Sendable {
    package let identity: DisplaySurfaceIdentity
    package let configID: UUID
    package let preDisplayID: DisplayRuntimeDisplayID?
    package let serialNumber: UInt32?
    package let reason: DisplayRuntimeAffectedSurfaceReason

    package init(
        identity: DisplaySurfaceIdentity,
        configID: UUID,
        preDisplayID: DisplayRuntimeDisplayID?,
        serialNumber: UInt32?,
        reason: DisplayRuntimeAffectedSurfaceReason
    ) {
        self.identity = identity
        self.configID = configID
        self.preDisplayID = preDisplayID
        self.serialNumber = serialNumber
        self.reason = reason
    }
}

package nonisolated enum DisplayRuntimeTransactionRecoverability: String, Codable, Equatable, Sendable {
    case retryable
    case degraded
    case unrecoverable
}

package nonisolated struct DisplayRuntimeTransactionFailure: Codable, Equatable, Sendable {
    package let phase: DisplayRuntimeTransactionPhase
    package let reason: String
    package let underlyingDomain: String?
    package let underlyingCode: Int?
    package let recoverability: DisplayRuntimeTransactionRecoverability

    package init(
        phase: DisplayRuntimeTransactionPhase,
        reason: String,
        underlyingDomain: String? = nil,
        underlyingCode: Int? = nil,
        recoverability: DisplayRuntimeTransactionRecoverability
    ) {
        self.phase = phase
        self.reason = reason
        self.underlyingDomain = underlyingDomain
        self.underlyingCode = underlyingCode
        self.recoverability = recoverability
    }
}

package nonisolated enum DisplayRuntimeCompensationStatus: String, Codable, Equatable, Sendable {
    case notRequired
    case skipped
    case completed
    case degraded
}

package nonisolated struct DisplayRuntimeCompensationResult: Codable, Equatable, Sendable {
    package let status: DisplayRuntimeCompensationStatus
    package let restoredSharingCount: Int
    package let restoredPreviewCount: Int
    package let failedRestoreCount: Int
    package let persistenceOutcome: DisplayRuntimePersistenceOutcome?
    package let virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome?
    package let failureReason: String?

    package init(
        status: DisplayRuntimeCompensationStatus,
        restoredSharingCount: Int,
        restoredPreviewCount: Int,
        failedRestoreCount: Int,
        persistenceOutcome: DisplayRuntimePersistenceOutcome? = nil,
        virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome? = nil,
        failureReason: String? = nil
    ) {
        self.status = status
        self.restoredSharingCount = restoredSharingCount
        self.restoredPreviewCount = restoredPreviewCount
        self.failedRestoreCount = failedRestoreCount
        self.persistenceOutcome = persistenceOutcome
        self.virtualDisplayCommandOutcome = virtualDisplayCommandOutcome
        self.failureReason = failureReason
    }

    package static let notRequired = Self(
        status: .notRequired,
        restoredSharingCount: 0,
        restoredPreviewCount: 0,
        failedRestoreCount: 0
    )
}
