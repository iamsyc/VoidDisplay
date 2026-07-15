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
                let previewCapturesCursor = pauseIntent.pausePreview
                    && preSnapshot.capture.sessions.contains {
                        $0.displayID == pauseIntent.displayID && $0.capturesCursor
                    }
                return DisplayRuntimeSessionRestoreIntent(
                    surfaceIdentity: pauseIntent.surfaceIdentity,
                    previousDisplayID: pauseIntent.displayID,
                    resolvedDisplayID: resolvedDisplayID,
                    restoreSharing: pauseIntent.pauseSharing,
                    restorePreview: pauseIntent.pausePreview,
                    previewCapturesCursor: previewCapturesCursor
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
        let restoredPreviewCount = restoreResults.filter { $0.kind == .preview && $0.status == .restored }.count
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
                restoredPreviewCount: restoredPreviewCount,
                failedRestoreCount: failedRestoreCount
            )
        case .unprovableDueToPermission, .failed, .timedOut:
            return .init(
                status: .degraded,
                restoredSharingCount: restoredSharingCount,
                restoredPreviewCount: restoredPreviewCount,
                failedRestoreCount: failedRestoreCount
            )
        }
    }

    func consumerCompensationResult(
        restoreResults: [DisplayRuntimeSessionRestoreResult],
        restoreIntentCount: Int
    ) -> DisplayRuntimeCompensationResult {
        guard restoreIntentCount > 0 else { return .notRequired }
        let restoredSharingCount = restoreResults.count {
            $0.kind == .sharing && $0.status == .restored
        }
        let restoredPreviewCount = restoreResults.count {
            $0.kind == .preview && $0.status == .restored
        }
        let failedRestoreCount = restoreResults.count {
            $0.status != .restored && !isTargetTerminalSkipReason($0.failureReason)
        }
        return DisplayRuntimeCompensationResult(
            status: failedRestoreCount == 0 ? .completed : .degraded,
            restoredSharingCount: restoredSharingCount,
            restoredPreviewCount: restoredPreviewCount,
            failedRestoreCount: failedRestoreCount
        )
    }

    func mergingCompensation(
        _ primary: DisplayRuntimeCompensationResult,
        with consumer: DisplayRuntimeCompensationResult
    ) -> DisplayRuntimeCompensationResult {
        let status: DisplayRuntimeCompensationStatus
        if primary.status == .degraded || consumer.status == .degraded {
            status = .degraded
        } else if primary.status == .completed || consumer.status == .completed {
            status = .completed
        } else if primary.status == .skipped || consumer.status == .skipped {
            status = .skipped
        } else {
            status = .notRequired
        }
        return DisplayRuntimeCompensationResult(
            status: status,
            restoredSharingCount: primary.restoredSharingCount + consumer.restoredSharingCount,
            restoredPreviewCount: primary.restoredPreviewCount + consumer.restoredPreviewCount,
            failedRestoreCount: primary.failedRestoreCount + consumer.failedRestoreCount,
            persistenceOutcome: primary.persistenceOutcome,
            virtualDisplayCommandOutcome: primary.virtualDisplayCommandOutcome,
            failureReason: primary.failureReason ?? consumer.failureReason
        )
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
            let pausePreview = surface.capture?.sessionIDs.isEmpty == false || surface.capture?.isStarting == true
            guard pauseSharing || pausePreview else {
                continue
            }
            if let existing = intentsByDisplayID[displayID] {
                intentsByDisplayID[displayID] = DisplayRuntimeSessionPauseIntent(
                    surfaceIdentity: existing.surfaceIdentity,
                    displayID: displayID,
                    pauseSharing: existing.pauseSharing || pauseSharing,
                    pausePreview: existing.pausePreview || pausePreview
                )
                continue
            }
            intentsByDisplayID[displayID] = DisplayRuntimeSessionPauseIntent(
                surfaceIdentity: affectedSurface.identity,
                displayID: displayID,
                pauseSharing: pauseSharing,
                pausePreview: pausePreview
            )
        }
        return intentsByDisplayID.values.sorted { $0.displayID < $1.displayID }
    }

    private func isTargetTerminalSkipReason(_ reason: String?) -> Bool {
        reason == "target_disabled"
            || reason == "target_deleted"
            || reason == "consumer_lease_released"
    }
}
