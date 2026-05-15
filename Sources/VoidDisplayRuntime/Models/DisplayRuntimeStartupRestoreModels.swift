import Foundation

package nonisolated struct DisplayRuntimeStartupRestoreRunID: Codable, Equatable, Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

package nonisolated enum DisplayRuntimeStartupRestoreDuplicateBehavior: String, Codable, Equatable, Sendable {
    case started
    case coalesced
    case alreadyCompleted
}

package nonisolated enum DisplayRuntimeStartupRestoreStatus: String, Codable, Equatable, Sendable {
    case succeeded
    case succeededNoOp
    case completedWithFailures
    case failed
}

package nonisolated enum DisplayRuntimeStartupRestoreConfigLoadStatus: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
}

package nonisolated struct DisplayRuntimeStartupRestoreConfig: Codable, Equatable, Sendable {
    package let id: UUID
    package let desiredEnabled: Bool
    package let evidence: DisplayRuntimeVirtualDisplayConfigEvidence

    package init(
        id: UUID,
        desiredEnabled: Bool,
        evidence: DisplayRuntimeVirtualDisplayConfigEvidence
    ) {
        self.id = id
        self.desiredEnabled = desiredEnabled
        self.evidence = evidence
    }
}

package nonisolated struct DisplayRuntimeStartupRestoreConfigLoadResult: Codable, Equatable, Sendable {
    package let status: DisplayRuntimeStartupRestoreConfigLoadStatus
    package let configs: [DisplayRuntimeStartupRestoreConfig]
    package let failureReason: String?
    package let underlyingDomain: String?
    package let underlyingCode: Int?

    package init(
        status: DisplayRuntimeStartupRestoreConfigLoadStatus,
        configs: [DisplayRuntimeStartupRestoreConfig],
        failureReason: String? = nil,
        underlyingDomain: String? = nil,
        underlyingCode: Int? = nil
    ) {
        self.status = status
        self.configs = configs
        self.failureReason = failureReason
        self.underlyingDomain = underlyingDomain
        self.underlyingCode = underlyingCode
    }

    package static func succeeded(configs: [DisplayRuntimeStartupRestoreConfig]) -> Self {
        Self(status: .succeeded, configs: configs)
    }

    package static func failed(
        reason: String,
        underlyingDomain: String? = nil,
        underlyingCode: Int? = nil
    ) -> Self {
        Self(
            status: .failed,
            configs: [],
            failureReason: reason,
            underlyingDomain: underlyingDomain,
            underlyingCode: underlyingCode
        )
    }
}

package nonisolated struct DisplayRuntimeStartupRestoreConfigLoadTrace: Codable, Equatable, Sendable {
    package let status: DisplayRuntimeStartupRestoreConfigLoadStatus
    package let persistedConfigIDs: [UUID]
    package let desiredEnabledConfigIDs: [UUID]
    package let desiredDisabledConfigIDs: [UUID]
    package let failureReason: String?
    package let underlyingDomain: String?
    package let underlyingCode: Int?

    package init(
        status: DisplayRuntimeStartupRestoreConfigLoadStatus,
        persistedConfigIDs: [UUID],
        desiredEnabledConfigIDs: [UUID],
        desiredDisabledConfigIDs: [UUID],
        failureReason: String?,
        underlyingDomain: String?,
        underlyingCode: Int?
    ) {
        self.status = status
        self.persistedConfigIDs = persistedConfigIDs.sortedByUUIDString()
        self.desiredEnabledConfigIDs = desiredEnabledConfigIDs.sortedByUUIDString()
        self.desiredDisabledConfigIDs = desiredDisabledConfigIDs.sortedByUUIDString()
        self.failureReason = failureReason
        self.underlyingDomain = underlyingDomain
        self.underlyingCode = underlyingCode
    }

    package init(loadResult: DisplayRuntimeStartupRestoreConfigLoadResult) {
        let desiredEnabled = loadResult.configs.filter(\.desiredEnabled).map(\.id)
        let desiredDisabled = loadResult.configs.filter { !$0.desiredEnabled }.map(\.id)
        self.init(
            status: loadResult.status,
            persistedConfigIDs: loadResult.configs.map(\.id),
            desiredEnabledConfigIDs: desiredEnabled,
            desiredDisabledConfigIDs: desiredDisabled,
            failureReason: loadResult.failureReason,
            underlyingDomain: loadResult.underlyingDomain,
            underlyingCode: loadResult.underlyingCode
        )
    }
}

package nonisolated struct DisplayRuntimeStartupRestoreIntent: Codable, Equatable, Sendable {
    package let runID: DisplayRuntimeStartupRestoreRunID
    package let configID: UUID
    package let configEvidence: DisplayRuntimeVirtualDisplayConfigEvidence

    package init(
        runID: DisplayRuntimeStartupRestoreRunID,
        configID: UUID,
        configEvidence: DisplayRuntimeVirtualDisplayConfigEvidence
    ) {
        self.runID = runID
        self.configID = configID
        self.configEvidence = configEvidence
    }
}

package nonisolated struct DisplayRuntimeStartupRestoreCommandRequest: Codable, Equatable, Sendable {
    package let transactionID: DisplayRuntimeTransactionID
    package let runID: DisplayRuntimeStartupRestoreRunID
    package let configID: UUID
    package let configEvidence: DisplayRuntimeVirtualDisplayConfigEvidence

    package init(
        transactionID: DisplayRuntimeTransactionID,
        runID: DisplayRuntimeStartupRestoreRunID,
        configID: UUID,
        configEvidence: DisplayRuntimeVirtualDisplayConfigEvidence
    ) {
        self.transactionID = transactionID
        self.runID = runID
        self.configID = configID
        self.configEvidence = configEvidence
    }
}

package nonisolated struct DisplayRuntimeStartupRestoreCommandResult: Codable, Equatable, Sendable {
    package let transactionID: DisplayRuntimeTransactionID
    package let configID: UUID
    package let preDisplayID: DisplayRuntimeDisplayID?
    package let postDisplayID: DisplayRuntimeDisplayID?
    package let restoreOutcome: DisplayRuntimeVirtualDisplayCommandOutcome
    package let didProduceVerifiableSideEffect: Bool
    package let failureReason: String?
    package let compensationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome
    package let compensationFailureReason: String?
    package let runningConfigIDsAfterCommand: [UUID]
    package let managedDisplaysAfterCommand: [DisplayRuntimeManagedVirtualDisplay]

    package init(
        transactionID: DisplayRuntimeTransactionID,
        configID: UUID,
        preDisplayID: DisplayRuntimeDisplayID?,
        postDisplayID: DisplayRuntimeDisplayID?,
        restoreOutcome: DisplayRuntimeVirtualDisplayCommandOutcome,
        didProduceVerifiableSideEffect: Bool,
        failureReason: String? = nil,
        compensationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome = .notAttempted,
        compensationFailureReason: String? = nil,
        runningConfigIDsAfterCommand: [UUID],
        managedDisplaysAfterCommand: [DisplayRuntimeManagedVirtualDisplay]
    ) {
        self.transactionID = transactionID
        self.configID = configID
        self.preDisplayID = preDisplayID
        self.postDisplayID = postDisplayID
        self.restoreOutcome = restoreOutcome
        self.didProduceVerifiableSideEffect = didProduceVerifiableSideEffect
        self.failureReason = failureReason
        self.compensationOutcome = compensationOutcome
        self.compensationFailureReason = compensationFailureReason
        self.runningConfigIDsAfterCommand = runningConfigIDsAfterCommand.sortedByUUIDString()
        self.managedDisplaysAfterCommand = managedDisplaysAfterCommand.sorted {
            ($0.configID.uuidString, $0.displayID) < ($1.configID.uuidString, $1.displayID)
        }
    }
}

package nonisolated struct DisplayRuntimeStartupRestoreCommandTrace: Codable, Equatable, Sendable {
    package let configID: UUID
    package let preDisplayID: DisplayRuntimeDisplayID?
    package let postDisplayID: DisplayRuntimeDisplayID?
    package let restoreOutcome: DisplayRuntimeVirtualDisplayCommandOutcome
    package let didProduceVerifiableSideEffect: Bool
    package let failureReason: String?
    package let compensationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome
    package let compensationFailureReason: String?
    package let runningConfigIDsAfterCommand: [UUID]

    package init(commandResult: DisplayRuntimeStartupRestoreCommandResult) {
        self.configID = commandResult.configID
        self.preDisplayID = commandResult.preDisplayID
        self.postDisplayID = commandResult.postDisplayID
        self.restoreOutcome = commandResult.restoreOutcome
        self.didProduceVerifiableSideEffect = commandResult.didProduceVerifiableSideEffect
        self.failureReason = commandResult.failureReason
        self.compensationOutcome = commandResult.compensationOutcome
        self.compensationFailureReason = commandResult.compensationFailureReason
        self.runningConfigIDsAfterCommand = commandResult.runningConfigIDsAfterCommand
    }

    package init(
        configID: UUID,
        preDisplayID: DisplayRuntimeDisplayID?,
        postDisplayID: DisplayRuntimeDisplayID?,
        restoreOutcome: DisplayRuntimeVirtualDisplayCommandOutcome,
        didProduceVerifiableSideEffect: Bool,
        failureReason: String?,
        compensationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome,
        compensationFailureReason: String?,
        runningConfigIDsAfterCommand: [UUID]
    ) {
        self.configID = configID
        self.preDisplayID = preDisplayID
        self.postDisplayID = postDisplayID
        self.restoreOutcome = restoreOutcome
        self.didProduceVerifiableSideEffect = didProduceVerifiableSideEffect
        self.failureReason = failureReason
        self.compensationOutcome = compensationOutcome
        self.compensationFailureReason = compensationFailureReason
        self.runningConfigIDsAfterCommand = runningConfigIDsAfterCommand.sortedByUUIDString()
    }
}

package nonisolated enum DisplayRuntimeStartupRestoreConfigResultStatus: String, Codable, Equatable, Sendable {
    case restored
    case degraded
    case failed
    case skipped
}

package nonisolated struct DisplayRuntimeStartupRestoreConfigResult: Codable, Equatable, Sendable {
    package let transactionID: DisplayRuntimeTransactionID
    package let configID: UUID
    package let status: DisplayRuntimeStartupRestoreConfigResultStatus
    package let restoreOutcome: DisplayRuntimeVirtualDisplayCommandOutcome
    package let failureReason: String?
    package let topologyStabilityResult: DisplayRuntimeTopologyStabilityResult?

    package init(
        transactionID: DisplayRuntimeTransactionID,
        configID: UUID,
        status: DisplayRuntimeStartupRestoreConfigResultStatus,
        restoreOutcome: DisplayRuntimeVirtualDisplayCommandOutcome,
        failureReason: String?,
        topologyStabilityResult: DisplayRuntimeTopologyStabilityResult?
    ) {
        self.transactionID = transactionID
        self.configID = configID
        self.status = status
        self.restoreOutcome = restoreOutcome
        self.failureReason = failureReason
        self.topologyStabilityResult = topologyStabilityResult
    }
}

package nonisolated struct DisplayRuntimeStartupRestoreResult: Codable, Equatable, Sendable {
    package let runID: DisplayRuntimeStartupRestoreRunID
    package let status: DisplayRuntimeStartupRestoreStatus
    package let source: DisplayRuntimeTransactionSource
    package let duplicateBehavior: DisplayRuntimeStartupRestoreDuplicateBehavior
    package let configLoadTrace: DisplayRuntimeStartupRestoreConfigLoadTrace
    package let configResults: [DisplayRuntimeStartupRestoreConfigResult]
    package let traceIDs: [DisplayRuntimeTransactionID]
    package let coalescedRequestCount: Int

    package init(
        runID: DisplayRuntimeStartupRestoreRunID,
        status: DisplayRuntimeStartupRestoreStatus,
        source: DisplayRuntimeTransactionSource,
        duplicateBehavior: DisplayRuntimeStartupRestoreDuplicateBehavior,
        configLoadTrace: DisplayRuntimeStartupRestoreConfigLoadTrace,
        configResults: [DisplayRuntimeStartupRestoreConfigResult],
        traceIDs: [DisplayRuntimeTransactionID],
        coalescedRequestCount: Int
    ) {
        self.runID = runID
        self.status = status
        self.source = source
        self.duplicateBehavior = duplicateBehavior
        self.configLoadTrace = configLoadTrace
        self.configResults = configResults.sorted { $0.configID.uuidString < $1.configID.uuidString }
        self.traceIDs = traceIDs.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        self.coalescedRequestCount = coalescedRequestCount
    }

    package func replacing(
        duplicateBehavior: DisplayRuntimeStartupRestoreDuplicateBehavior? = nil,
        coalescedRequestCount: Int? = nil
    ) -> Self {
        Self(
            runID: runID,
            status: status,
            source: source,
            duplicateBehavior: duplicateBehavior ?? self.duplicateBehavior,
            configLoadTrace: configLoadTrace,
            configResults: configResults,
            traceIDs: traceIDs,
            coalescedRequestCount: coalescedRequestCount ?? self.coalescedRequestCount
        )
    }
}

private nonisolated extension Array where Element == UUID {
    func sortedByUUIDString() -> [UUID] {
        sorted { $0.uuidString < $1.uuidString }
    }
}
