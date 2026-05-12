import Foundation

package nonisolated struct DisplayRuntimeTransactionID: Codable, Equatable, Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

package nonisolated enum DisplayRuntimeTransactionKind: String, Codable, Equatable, Sendable {
    case virtualDisplayRebuild
}

package nonisolated enum DisplayRuntimeTransactionSource: String, Codable, Equatable, Sendable {
    case virtualDisplayRowRetry
    case editSaveAndRebuild
    case diagnostics
    case unknown
}

package nonisolated enum DisplayRuntimeTransactionPhase: String, Codable, Equatable, Sendable {
    case queued
    case preparing
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

package nonisolated struct DisplayRuntimeVirtualDisplayRebuildTransactionResult: Codable, Equatable, Sendable {
    package let transactionID: DisplayRuntimeTransactionID
    package let status: DisplayRuntimeTransactionStatus
    package let virtualDisplayCommandSucceeded: Bool
    package let hasSessionRecoveryFailures: Bool

    package init(
        transactionID: DisplayRuntimeTransactionID,
        status: DisplayRuntimeTransactionStatus,
        virtualDisplayCommandSucceeded: Bool,
        hasSessionRecoveryFailures: Bool
    ) {
        self.transactionID = transactionID
        self.status = status
        self.virtualDisplayCommandSucceeded = virtualDisplayCommandSucceeded
        self.hasSessionRecoveryFailures = hasSessionRecoveryFailures
    }
}

package nonisolated enum DisplayRuntimeAffectedSurfaceReason: String, Codable, Equatable, Sendable {
    case requestedConfig
    case managedMainFleetPeer
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

package nonisolated struct DisplayRuntimeSessionPauseIntent: Codable, Equatable, Sendable {
    package let surfaceIdentity: DisplaySurfaceIdentity
    package let displayID: DisplayRuntimeDisplayID
    package let pauseSharing: Bool
    package let pauseMonitoring: Bool

    package init(
        surfaceIdentity: DisplaySurfaceIdentity,
        displayID: DisplayRuntimeDisplayID,
        pauseSharing: Bool,
        pauseMonitoring: Bool
    ) {
        self.surfaceIdentity = surfaceIdentity
        self.displayID = displayID
        self.pauseSharing = pauseSharing
        self.pauseMonitoring = pauseMonitoring
    }
}

package nonisolated struct DisplayRuntimeSessionRestoreIntent: Codable, Equatable, Sendable {
    package let surfaceIdentity: DisplaySurfaceIdentity
    package let previousDisplayID: DisplayRuntimeDisplayID?
    package let resolvedDisplayID: DisplayRuntimeDisplayID?
    package let restoreSharing: Bool
    package let restoreMonitoring: Bool
    package let monitoringCapturesCursor: Bool

    package init(
        surfaceIdentity: DisplaySurfaceIdentity,
        previousDisplayID: DisplayRuntimeDisplayID?,
        resolvedDisplayID: DisplayRuntimeDisplayID?,
        restoreSharing: Bool,
        restoreMonitoring: Bool,
        monitoringCapturesCursor: Bool
    ) {
        self.surfaceIdentity = surfaceIdentity
        self.previousDisplayID = previousDisplayID
        self.resolvedDisplayID = resolvedDisplayID
        self.restoreSharing = restoreSharing
        self.restoreMonitoring = restoreMonitoring
        self.monitoringCapturesCursor = monitoringCapturesCursor
    }
}

package nonisolated enum DisplayRuntimeSessionRestoreKind: String, Codable, Equatable, Sendable {
    case sharing
    case monitoring
}

package nonisolated enum DisplayRuntimeSessionRestoreStatus: String, Codable, Equatable, Sendable {
    case skipped
    case restored
    case failed
    case invalidated
}

package nonisolated struct DisplayRuntimeSessionRestoreResult: Codable, Equatable, Sendable {
    package let kind: DisplayRuntimeSessionRestoreKind
    package let status: DisplayRuntimeSessionRestoreStatus
    package let previousDisplayID: DisplayRuntimeDisplayID?
    package let resolvedDisplayID: DisplayRuntimeDisplayID?
    package let failureReason: String?

    package init(
        kind: DisplayRuntimeSessionRestoreKind,
        status: DisplayRuntimeSessionRestoreStatus,
        previousDisplayID: DisplayRuntimeDisplayID?,
        resolvedDisplayID: DisplayRuntimeDisplayID?,
        failureReason: String?
    ) {
        self.kind = kind
        self.status = status
        self.previousDisplayID = previousDisplayID
        self.resolvedDisplayID = resolvedDisplayID
        self.failureReason = failureReason
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

package nonisolated struct DisplayRuntimeTransactionSnapshotEvidence: Codable, Equatable, Sendable {
    package let surfaces: [DisplaySurface]
    package let catalogTopologySignature: [DisplayRuntimeCatalogTopologyEntry]
    package let visibleDisplayIDs: [DisplayRuntimeDisplayID]
    package let captureSessions: [DisplayRuntimeCaptureSession]
    package let sharingDisplayIDs: [DisplayRuntimeDisplayID]
    package let managedVirtualDisplays: [DisplayRuntimeManagedVirtualDisplay]
    package let runningConfigIDs: [UUID]

    package init(
        surfaces: [DisplaySurface],
        catalogTopologySignature: [DisplayRuntimeCatalogTopologyEntry],
        visibleDisplayIDs: [DisplayRuntimeDisplayID],
        captureSessions: [DisplayRuntimeCaptureSession],
        sharingDisplayIDs: [DisplayRuntimeDisplayID],
        managedVirtualDisplays: [DisplayRuntimeManagedVirtualDisplay],
        runningConfigIDs: [UUID]
    ) {
        self.surfaces = surfaces.sorted {
            ($0.kind.rawValue, $0.identity.stableID) < ($1.kind.rawValue, $1.identity.stableID)
        }
        self.catalogTopologySignature = catalogTopologySignature.sorted { $0.displayID < $1.displayID }
        self.visibleDisplayIDs = visibleDisplayIDs.sorted()
        self.captureSessions = captureSessions.sorted { $0.id.uuidString < $1.id.uuidString }
        self.sharingDisplayIDs = sharingDisplayIDs.sorted()
        self.managedVirtualDisplays = managedVirtualDisplays.sorted {
            ($0.configID.uuidString, $0.displayID) < ($1.configID.uuidString, $1.displayID)
        }
        self.runningConfigIDs = runningConfigIDs.sorted { $0.uuidString < $1.uuidString }
    }

    package init(snapshot: DisplayRuntimeSnapshot) {
        self.init(
            surfaces: snapshot.surfaces,
            catalogTopologySignature: snapshot.catalog.topologySignature,
            visibleDisplayIDs: snapshot.catalog.loadedDisplays.map(\.displayID),
            captureSessions: snapshot.capture.sessions,
            sharingDisplayIDs: snapshot.sharing.activeSharingDisplayIDs,
            managedVirtualDisplays: snapshot.virtualDisplay.managedDisplays,
            runningConfigIDs: snapshot.virtualDisplay.runningConfigIDs
        )
    }
}

package nonisolated struct DisplayRuntimeTopologyStabilitySample: Codable, Equatable, Sendable {
    package let topologySignature: [DisplayRuntimeCatalogTopologyEntry]
    package let visibleDisplayIDs: [DisplayRuntimeDisplayID]
    package let managedVirtualDisplays: [DisplayRuntimeTopologyManagedVirtualDisplaySample]

    package init(
        topologySignature: [DisplayRuntimeCatalogTopologyEntry],
        visibleDisplayIDs: [DisplayRuntimeDisplayID],
        managedVirtualDisplays: [DisplayRuntimeTopologyManagedVirtualDisplaySample]
    ) {
        self.topologySignature = topologySignature.sorted { $0.displayID < $1.displayID }
        self.visibleDisplayIDs = visibleDisplayIDs.sorted()
        self.managedVirtualDisplays = managedVirtualDisplays.sorted {
            ($0.configID.uuidString, $0.displayID, $0.isLiveRuntime ? 1 : 0)
                < ($1.configID.uuidString, $1.displayID, $1.isLiveRuntime ? 1 : 0)
        }
    }

    package init(snapshot: DisplayRuntimeSnapshot) {
        self.init(
            topologySignature: snapshot.catalog.topologySignature,
            visibleDisplayIDs: snapshot.catalog.loadedDisplays.map(\.displayID),
            managedVirtualDisplays: snapshot.virtualDisplay.managedDisplays.map {
                .init(
                    configID: $0.configID,
                    displayID: $0.displayID,
                    isLiveRuntime: $0.isLiveRuntime
                )
            }
        )
    }
}

package nonisolated struct DisplayRuntimeTopologyManagedVirtualDisplaySample: Codable, Equatable, Sendable {
    package let configID: UUID
    package let displayID: DisplayRuntimeDisplayID
    package let isLiveRuntime: Bool

    package init(
        configID: UUID,
        displayID: DisplayRuntimeDisplayID,
        isLiveRuntime: Bool
    ) {
        self.configID = configID
        self.displayID = displayID
        self.isLiveRuntime = isLiveRuntime
    }
}

package nonisolated enum DisplayRuntimeTopologyStabilityStatus: String, Codable, Equatable, Sendable {
    case stable
    case unprovableDueToPermission
    case failed
    case timedOut
}

package nonisolated struct DisplayRuntimeTopologyStabilityResult: Codable, Equatable, Sendable {
    package let status: DisplayRuntimeTopologyStabilityStatus
    package let sampleCount: Int
    package let failureReason: String?
    package let lastSample: DisplayRuntimeTopologyStabilitySample?

    package init(
        status: DisplayRuntimeTopologyStabilityStatus,
        sampleCount: Int,
        failureReason: String?,
        lastSample: DisplayRuntimeTopologyStabilitySample?
    ) {
        self.status = status
        self.sampleCount = sampleCount
        self.failureReason = failureReason
        self.lastSample = lastSample
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
    package let restoredMonitoringCount: Int
    package let failedRestoreCount: Int

    package init(
        status: DisplayRuntimeCompensationStatus,
        restoredSharingCount: Int,
        restoredMonitoringCount: Int,
        failedRestoreCount: Int
    ) {
        self.status = status
        self.restoredSharingCount = restoredSharingCount
        self.restoredMonitoringCount = restoredMonitoringCount
        self.failedRestoreCount = failedRestoreCount
    }

    package static let notRequired = Self(
        status: .notRequired,
        restoredSharingCount: 0,
        restoredMonitoringCount: 0,
        failedRestoreCount: 0
    )
}

package nonisolated struct DisplayRuntimeTransactionTrace: Codable, Equatable, Sendable {
    package let id: DisplayRuntimeTransactionID
    package let kind: DisplayRuntimeTransactionKind
    package let source: DisplayRuntimeTransactionSource
    package let status: DisplayRuntimeTransactionStatus
    package let phases: [DisplayRuntimeTransactionPhaseRecord]
    package let affectedSurfaces: [DisplayRuntimeAffectedSurface]
    package let preSnapshotEvidence: DisplayRuntimeTransactionSnapshotEvidence?
    package let postSnapshotEvidence: DisplayRuntimeTransactionSnapshotEvidence?
    package let pauseIntents: [DisplayRuntimeSessionPauseIntent]
    package let restoreIntents: [DisplayRuntimeSessionRestoreIntent]
    package let restoreResults: [DisplayRuntimeSessionRestoreResult]
    package let topologyStabilityResult: DisplayRuntimeTopologyStabilityResult?
    package let failure: DisplayRuntimeTransactionFailure?
    package let compensation: DisplayRuntimeCompensationResult
    package let coalescedRequestCount: Int

    package init(
        id: DisplayRuntimeTransactionID,
        kind: DisplayRuntimeTransactionKind,
        source: DisplayRuntimeTransactionSource,
        status: DisplayRuntimeTransactionStatus,
        phases: [DisplayRuntimeTransactionPhaseRecord],
        affectedSurfaces: [DisplayRuntimeAffectedSurface],
        preSnapshotEvidence: DisplayRuntimeTransactionSnapshotEvidence?,
        postSnapshotEvidence: DisplayRuntimeTransactionSnapshotEvidence?,
        pauseIntents: [DisplayRuntimeSessionPauseIntent],
        restoreIntents: [DisplayRuntimeSessionRestoreIntent],
        restoreResults: [DisplayRuntimeSessionRestoreResult],
        topologyStabilityResult: DisplayRuntimeTopologyStabilityResult? = nil,
        failure: DisplayRuntimeTransactionFailure?,
        compensation: DisplayRuntimeCompensationResult,
        coalescedRequestCount: Int
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.status = status
        self.phases = phases
        self.affectedSurfaces = affectedSurfaces.sorted {
            ($0.reason.rawValue, $0.identity.stableID) < ($1.reason.rawValue, $1.identity.stableID)
        }
        self.preSnapshotEvidence = preSnapshotEvidence
        self.postSnapshotEvidence = postSnapshotEvidence
        self.pauseIntents = pauseIntents.sorted { $0.displayID < $1.displayID }
        self.restoreIntents = restoreIntents.sorted {
            ($0.previousDisplayID ?? 0, $0.surfaceIdentity.stableID) < ($1.previousDisplayID ?? 0, $1.surfaceIdentity.stableID)
        }
        self.restoreResults = restoreResults
        self.topologyStabilityResult = topologyStabilityResult
        self.failure = failure
        self.compensation = compensation
        self.coalescedRequestCount = coalescedRequestCount
    }

    package func replacing(
        status: DisplayRuntimeTransactionStatus? = nil,
        phases: [DisplayRuntimeTransactionPhaseRecord]? = nil,
        affectedSurfaces: [DisplayRuntimeAffectedSurface]? = nil,
        preSnapshotEvidence: DisplayRuntimeTransactionSnapshotEvidence? = nil,
        postSnapshotEvidence: DisplayRuntimeTransactionSnapshotEvidence? = nil,
        pauseIntents: [DisplayRuntimeSessionPauseIntent]? = nil,
        restoreIntents: [DisplayRuntimeSessionRestoreIntent]? = nil,
        restoreResults: [DisplayRuntimeSessionRestoreResult]? = nil,
        topologyStabilityResult: DisplayRuntimeTopologyStabilityResult? = nil,
        failure: DisplayRuntimeTransactionFailure? = nil,
        compensation: DisplayRuntimeCompensationResult? = nil,
        coalescedRequestCount: Int? = nil
    ) -> Self {
        Self(
            id: id,
            kind: kind,
            source: source,
            status: status ?? self.status,
            phases: phases ?? self.phases,
            affectedSurfaces: affectedSurfaces ?? self.affectedSurfaces,
            preSnapshotEvidence: preSnapshotEvidence ?? self.preSnapshotEvidence,
            postSnapshotEvidence: postSnapshotEvidence ?? self.postSnapshotEvidence,
            pauseIntents: pauseIntents ?? self.pauseIntents,
            restoreIntents: restoreIntents ?? self.restoreIntents,
            restoreResults: restoreResults ?? self.restoreResults,
            topologyStabilityResult: topologyStabilityResult ?? self.topologyStabilityResult,
            failure: failure ?? self.failure,
            compensation: compensation ?? self.compensation,
            coalescedRequestCount: coalescedRequestCount ?? self.coalescedRequestCount
        )
    }
}

package nonisolated struct DisplayRuntimeTransactionSnapshot: Codable, Equatable, Sendable {
    package let activeTransactions: [DisplayRuntimeTransactionTrace]
    package let recentTransactions: [DisplayRuntimeTransactionTrace]

    package init(
        activeTransactions: [DisplayRuntimeTransactionTrace],
        recentTransactions: [DisplayRuntimeTransactionTrace]
    ) {
        self.activeTransactions = activeTransactions.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        self.recentTransactions = recentTransactions
    }

    package static let empty = Self(activeTransactions: [], recentTransactions: [])
}
