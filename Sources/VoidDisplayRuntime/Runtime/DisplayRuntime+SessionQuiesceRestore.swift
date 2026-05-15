import Foundation

@MainActor
extension DisplayRuntime {
    func makeLifecycleSessionRestoreIntents(
        kind: DisplayRuntimeTransactionKind,
        targetConfigID: UUID,
        pauseIntents: [DisplayRuntimeSessionPauseIntent],
        topologyResult: DisplayRuntimeTopologyStabilityResult,
        preSnapshot: DisplayRuntimeSnapshot,
        postSnapshot: DisplayRuntimeSnapshot
    ) -> [DisplayRuntimeSessionRestoreIntent] {
        let targetIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: targetConfigID)
        let intents: [DisplayRuntimeSessionPauseIntent]
        switch kind {
        case .virtualDisplayEnable:
            intents = pauseIntents.filter { $0.surfaceIdentity != targetIdentity }
        case .virtualDisplayDisable, .virtualDisplayRebuild, .virtualDisplayEditRebuild, .virtualDisplayDelete,
             .virtualDisplayStartupRestore:
            intents = pauseIntents
        case .virtualDisplayCreate:
            intents = []
        }
        return makeSessionRestoreIntents(
            pauseIntents: intents,
            topologyResult: topologyResult,
            preSnapshot: preSnapshot,
            postSnapshot: postSnapshot
        )
    }

    func makeSessionRestoreIntents(
        pauseIntents: [DisplayRuntimeSessionPauseIntent],
        topologyResult: DisplayRuntimeTopologyStabilityResult,
        preSnapshot: DisplayRuntimeSnapshot,
        postSnapshot: DisplayRuntimeSnapshot
    ) -> [DisplayRuntimeSessionRestoreIntent] {
        let visibleDisplayIDs = Set(postSnapshot.catalog.loadedDisplays.map(\.displayID))
        return pauseIntents
            .map { pauseIntent in
                let resolvedDisplayID: DisplayRuntimeDisplayID? = {
                    guard topologyResult.status == .stable,
                          let surface = postSnapshot.surfaces.first(where: { $0.identity == pauseIntent.surfaceIdentity }),
                          let displayID = surface.currentDisplayID,
                          surface.managedVirtualDisplay?.isRunning != false,
                          visibleDisplayIDs.contains(displayID)
                    else {
                        return nil
                    }
                    return displayID
                }()
                let monitoringCapturesCursor = pauseIntent.pauseMonitoring
                    && preSnapshot.capture.sessions.contains {
                        $0.displayID == pauseIntent.displayID && $0.capturesCursor
                    }
                return DisplayRuntimeSessionRestoreIntent(
                    surfaceIdentity: pauseIntent.surfaceIdentity,
                    previousDisplayID: pauseIntent.displayID,
                    resolvedDisplayID: resolvedDisplayID,
                    restoreSharing: pauseIntent.pauseSharing,
                    restoreMonitoring: pauseIntent.pauseMonitoring,
                    monitoringCapturesCursor: monitoringCapturesCursor
                )
            }
    }

    func restoreSharingSessions(
        _ restoreIntents: [DisplayRuntimeSessionRestoreIntent],
        topologyResult: DisplayRuntimeTopologyStabilityResult,
        postSnapshot: DisplayRuntimeSnapshot,
        disabledTargetIdentity: DisplaySurfaceIdentity?,
        targetSkipReason: String = "target_disabled"
    ) async -> [DisplayRuntimeSessionRestoreResult] {
        let sharingRestoreIntents = restoreIntents.filter(\.restoreSharing)
        guard !sharingRestoreIntents.isEmpty else { return [] }

        let disabledTargetResults = sharingRestoreIntents
            .filter { $0.surfaceIdentity == disabledTargetIdentity }
            .map {
                makeRestoreResult(
                    kind: .sharing,
                    intent: $0,
                    status: .skipped,
                    failureReason: targetSkipReason
                )
            }
        let peerSharingRestoreIntents = sharingRestoreIntents.filter { $0.surfaceIdentity != disabledTargetIdentity }
        guard !peerSharingRestoreIntents.isEmpty else { return disabledTargetResults }

        guard topologyResult.status == .stable else {
            return disabledTargetResults + peerSharingRestoreIntents.map {
                makeRestoreResult(
                    kind: .sharing,
                    intent: $0,
                    status: .skipped,
                    failureReason: "topology_\(topologyResult.status.rawValue)"
                )
            }
        }

        guard postSnapshot.sharing.isWebServiceRunning else {
            return disabledTargetResults + peerSharingRestoreIntents.map {
                makeRestoreResult(
                    kind: .sharing,
                    intent: $0,
                    status: .skipped,
                    failureReason: "web_service_not_running"
                )
            }
        }

        let visibleDisplayIDs = Set(postSnapshot.catalog.loadedDisplays.map(\.displayID))
        var results: [DisplayRuntimeSessionRestoreResult] = disabledTargetResults
        for intent in peerSharingRestoreIntents {
            guard let resolvedDisplayID = intent.resolvedDisplayID else {
                results.append(
                    makeRestoreResult(
                        kind: .sharing,
                        intent: intent,
                        status: .skipped,
                        failureReason: "resolved_display_unavailable"
                    )
                )
                continue
            }
            guard visibleDisplayIDs.contains(resolvedDisplayID) else {
                results.append(
                    makeRestoreResult(
                        kind: .sharing,
                        intent: intent,
                        status: .skipped,
                        failureReason: "resolved_display_not_visible"
                    )
                )
                continue
            }
            guard let sharingCommander else {
                results.append(
                    makeRestoreResult(
                        kind: .sharing,
                        intent: intent,
                        status: .failed,
                        failureReason: "sharing_commander_unavailable"
                    )
                )
                continue
            }

            let commandResult = await sharingCommander.restoreSharing(displayID: resolvedDisplayID)
            results.append(
                makeRestoreResult(
                    kind: .sharing,
                    intent: intent,
                    status: commandResult.status,
                    failureReason: commandResult.failureReason
                )
            )
        }
        return results
    }

    func makeDeferredMonitoringRestoreResults(
        _ restoreIntents: [DisplayRuntimeSessionRestoreIntent],
        topologyResult: DisplayRuntimeTopologyStabilityResult,
        disabledTargetIdentity: DisplaySurfaceIdentity?,
        targetSkipReason: String = "target_disabled"
    ) -> [DisplayRuntimeSessionRestoreResult] {
        let monitoringRestoreIntents = restoreIntents.filter(\.restoreMonitoring)
        guard !monitoringRestoreIntents.isEmpty else { return [] }

        return monitoringRestoreIntents.map { intent in
            let failureReason: String = {
                guard intent.surfaceIdentity != disabledTargetIdentity else {
                    return targetSkipReason
                }
                guard topologyResult.status == .stable else {
                    return "topology_\(topologyResult.status.rawValue)"
                }
                guard intent.resolvedDisplayID != nil else {
                    return "resolved_display_unavailable"
                }
                return "monitoring_restore_deferred_until_consumer_lease"
            }()
            return makeRestoreResult(
                kind: .monitoring,
                intent: intent,
                status: .skipped,
                failureReason: failureReason
            )
        }
    }

    func transactionStatus(
        after topologyResult: DisplayRuntimeTopologyStabilityResult,
        restoreResults: [DisplayRuntimeSessionRestoreResult]
    ) -> DisplayRuntimeTransactionStatus {
        switch topologyResult.status {
        case .stable:
            return restoreResults.allSatisfy {
                $0.status == .restored || isTargetTerminalSkipReason($0.failureReason)
            }
                ? .completed
                : .completedWithRecoveryFailures
        case .unprovableDueToPermission, .failed, .timedOut:
            return .completedWithRecoveryFailures
        }
    }

    func compensationResult(
        after topologyResult: DisplayRuntimeTopologyStabilityResult,
        restoreResults: [DisplayRuntimeSessionRestoreResult],
        restoreIntentCount: Int
    ) -> DisplayRuntimeCompensationResult {
        let restoredSharingCount = restoreResults.filter { $0.kind == .sharing && $0.status == .restored }.count
        let failedRestoreCount = restoreResults.filter {
            $0.status != .restored && !isTargetTerminalSkipReason($0.failureReason)
        }.count
        switch topologyResult.status {
        case .stable:
            if restoreIntentCount == 0 {
                return .notRequired
            }
            return .init(
                status: failedRestoreCount == 0 ? .completed : .degraded,
                restoredSharingCount: restoredSharingCount,
                restoredMonitoringCount: 0,
                failedRestoreCount: failedRestoreCount
            )
        case .unprovableDueToPermission, .failed, .timedOut:
            return .init(
                status: .degraded,
                restoredSharingCount: restoredSharingCount,
                restoredMonitoringCount: 0,
                failedRestoreCount: failedRestoreCount
            )
        }
    }

    func makePauseIntents(
        affectedSurfaces: [DisplayRuntimeAffectedSurface],
        snapshot: DisplayRuntimeSnapshot
    ) -> [DisplayRuntimeSessionPauseIntent] {
        var intentsByDisplayID: [DisplayRuntimeDisplayID: DisplayRuntimeSessionPauseIntent] = [:]
        for affectedSurface in affectedSurfaces {
            guard let displayID = affectedSurface.preDisplayID,
                  let surface = snapshot.surfaces.first(where: { $0.identity == affectedSurface.identity })
            else {
                continue
            }
            let pauseSharing = surface.sharing?.isActive == true
            let pauseMonitoring = surface.capture?.sessionIDs.isEmpty == false || surface.capture?.isStarting == true
            guard pauseSharing || pauseMonitoring else {
                continue
            }
            if let existing = intentsByDisplayID[displayID] {
                intentsByDisplayID[displayID] = DisplayRuntimeSessionPauseIntent(
                    surfaceIdentity: existing.surfaceIdentity,
                    displayID: displayID,
                    pauseSharing: existing.pauseSharing || pauseSharing,
                    pauseMonitoring: existing.pauseMonitoring || pauseMonitoring
                )
                continue
            }
            intentsByDisplayID[displayID] = DisplayRuntimeSessionPauseIntent(
                surfaceIdentity: affectedSurface.identity,
                displayID: displayID,
                pauseSharing: pauseSharing,
                pauseMonitoring: pauseMonitoring
            )
        }
        return intentsByDisplayID.values.sorted { $0.displayID < $1.displayID }
    }

    func quiesceSessions(_ pauseIntents: [DisplayRuntimeSessionPauseIntent]) {
        for intent in pauseIntents.sorted(by: { $0.displayID < $1.displayID }) {
            if intent.pauseSharing {
                sharingCommander?.stopSharing(displayID: intent.displayID)
            }
            if intent.pauseMonitoring {
                captureCommander?.removeMonitoringSessions(displayID: intent.displayID)
            }
        }
    }

    private func makeRestoreResult(
        kind: DisplayRuntimeSessionRestoreKind,
        intent: DisplayRuntimeSessionRestoreIntent,
        status: DisplayRuntimeSessionRestoreStatus,
        failureReason: String?
    ) -> DisplayRuntimeSessionRestoreResult {
        DisplayRuntimeSessionRestoreResult(
            kind: kind,
            status: status,
            previousDisplayID: intent.previousDisplayID,
            resolvedDisplayID: intent.resolvedDisplayID,
            failureReason: failureReason
        )
    }

    private func isTargetTerminalSkipReason(_ reason: String?) -> Bool {
        reason == "target_disabled" || reason == "target_deleted"
    }
}
