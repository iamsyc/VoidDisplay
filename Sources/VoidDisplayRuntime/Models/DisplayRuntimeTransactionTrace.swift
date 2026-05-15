import Foundation

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
    package let persistenceOutcome: DisplayRuntimePersistenceOutcome
    package let virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome
    package let scopeEscalationReason: DisplayRuntimeScopeEscalationReason?
    package let enablePreflight: DisplayRuntimeVirtualDisplayEnablePreflight?
    package let oldConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence?
    package let editedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence?
    package let savedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence?
    package let targetConfigID: UUID?
    package let createdConfigID: UUID?
    package let createdConfigEvidence: DisplayRuntimeVirtualDisplayCreateConfigEvidence?
    package let runtimeCreationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome
    package let rollbackOutcome: DisplayRuntimePersistenceOutcome
    package let runtimeTrackingClearOutcome: DisplayRuntimeVirtualDisplayRuntimeTrackingClearOutcome
    package let startupRestoreRunID: DisplayRuntimeStartupRestoreRunID?
    package let startupConfigLoadResult: DisplayRuntimeStartupRestoreConfigLoadTrace?
    package let startupRestoreIntent: DisplayRuntimeStartupRestoreIntent?
    package let startupRestoreCommandResult: DisplayRuntimeStartupRestoreCommandTrace?

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
        coalescedRequestCount: Int,
        persistenceOutcome: DisplayRuntimePersistenceOutcome = .notAttempted,
        virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome = .notAttempted,
        scopeEscalationReason: DisplayRuntimeScopeEscalationReason? = nil,
        enablePreflight: DisplayRuntimeVirtualDisplayEnablePreflight? = nil,
        oldConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence? = nil,
        editedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence? = nil,
        savedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence? = nil,
        targetConfigID: UUID? = nil,
        createdConfigID: UUID? = nil,
        createdConfigEvidence: DisplayRuntimeVirtualDisplayCreateConfigEvidence? = nil,
        runtimeCreationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome = .notAttempted,
        rollbackOutcome: DisplayRuntimePersistenceOutcome = .notAttempted,
        runtimeTrackingClearOutcome: DisplayRuntimeVirtualDisplayRuntimeTrackingClearOutcome = .notAttempted,
        startupRestoreRunID: DisplayRuntimeStartupRestoreRunID? = nil,
        startupConfigLoadResult: DisplayRuntimeStartupRestoreConfigLoadTrace? = nil,
        startupRestoreIntent: DisplayRuntimeStartupRestoreIntent? = nil,
        startupRestoreCommandResult: DisplayRuntimeStartupRestoreCommandTrace? = nil
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
        self.persistenceOutcome = persistenceOutcome
        self.virtualDisplayCommandOutcome = virtualDisplayCommandOutcome
        self.scopeEscalationReason = scopeEscalationReason
        self.enablePreflight = enablePreflight
        self.oldConfigEvidence = oldConfigEvidence
        self.editedConfigEvidence = editedConfigEvidence
        self.savedConfigEvidence = savedConfigEvidence
        self.targetConfigID = targetConfigID
        self.createdConfigID = createdConfigID
        self.createdConfigEvidence = createdConfigEvidence
        self.runtimeCreationOutcome = runtimeCreationOutcome
        self.rollbackOutcome = rollbackOutcome
        self.runtimeTrackingClearOutcome = runtimeTrackingClearOutcome
        self.startupRestoreRunID = startupRestoreRunID
        self.startupConfigLoadResult = startupConfigLoadResult
        self.startupRestoreIntent = startupRestoreIntent
        self.startupRestoreCommandResult = startupRestoreCommandResult
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
        coalescedRequestCount: Int? = nil,
        persistenceOutcome: DisplayRuntimePersistenceOutcome? = nil,
        virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome? = nil,
        scopeEscalationReason: DisplayRuntimeScopeEscalationReason? = nil,
        enablePreflight: DisplayRuntimeVirtualDisplayEnablePreflight? = nil,
        oldConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence? = nil,
        editedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence? = nil,
        savedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence? = nil,
        targetConfigID: UUID? = nil,
        createdConfigID: UUID? = nil,
        createdConfigEvidence: DisplayRuntimeVirtualDisplayCreateConfigEvidence? = nil,
        runtimeCreationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome? = nil,
        rollbackOutcome: DisplayRuntimePersistenceOutcome? = nil,
        runtimeTrackingClearOutcome: DisplayRuntimeVirtualDisplayRuntimeTrackingClearOutcome? = nil,
        startupRestoreRunID: DisplayRuntimeStartupRestoreRunID? = nil,
        startupConfigLoadResult: DisplayRuntimeStartupRestoreConfigLoadTrace? = nil,
        startupRestoreIntent: DisplayRuntimeStartupRestoreIntent? = nil,
        startupRestoreCommandResult: DisplayRuntimeStartupRestoreCommandTrace? = nil
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
            coalescedRequestCount: coalescedRequestCount ?? self.coalescedRequestCount,
            persistenceOutcome: persistenceOutcome ?? self.persistenceOutcome,
            virtualDisplayCommandOutcome: virtualDisplayCommandOutcome ?? self.virtualDisplayCommandOutcome,
            scopeEscalationReason: scopeEscalationReason ?? self.scopeEscalationReason,
            enablePreflight: enablePreflight ?? self.enablePreflight,
            oldConfigEvidence: oldConfigEvidence ?? self.oldConfigEvidence,
            editedConfigEvidence: editedConfigEvidence ?? self.editedConfigEvidence,
            savedConfigEvidence: savedConfigEvidence ?? self.savedConfigEvidence,
            targetConfigID: targetConfigID ?? self.targetConfigID,
            createdConfigID: createdConfigID ?? self.createdConfigID,
            createdConfigEvidence: createdConfigEvidence ?? self.createdConfigEvidence,
            runtimeCreationOutcome: runtimeCreationOutcome ?? self.runtimeCreationOutcome,
            rollbackOutcome: rollbackOutcome ?? self.rollbackOutcome,
            runtimeTrackingClearOutcome: runtimeTrackingClearOutcome ?? self.runtimeTrackingClearOutcome,
            startupRestoreRunID: startupRestoreRunID ?? self.startupRestoreRunID,
            startupConfigLoadResult: startupConfigLoadResult ?? self.startupConfigLoadResult,
            startupRestoreIntent: startupRestoreIntent ?? self.startupRestoreIntent,
            startupRestoreCommandResult: startupRestoreCommandResult ?? self.startupRestoreCommandResult
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
