import Foundation

nonisolated struct DisplayRuntimeConsumerTransition: Sendable {
    let affectedSurface: DisplaySurfaceIdentity
    let previousDisplayID: DisplayRuntimeDisplayID?
    let leaseID: DisplayRuntimeConsumerLeaseID
    let consumerKind: DisplaySurfaceConsumerKind
    let demand: DisplayRuntimeConsumerDemand
    let epoch: DisplaySurfaceEpoch
}

nonisolated struct DisplayRuntimeConsumerTransitionBatch: Sendable {
    let affectedSurfaceIdentities: [DisplaySurfaceIdentity]
    let transitions: [DisplayRuntimeConsumerTransition]
    let epochsBySurface: [DisplaySurfaceIdentity: DisplaySurfaceEpoch]
    let quiesceFailures: [DisplayRuntimeCaptureIntentApplyResult]

    var restoreIntentCount: Int {
        transitions.count
    }

    var hasQuiesceFailure: Bool {
        !quiesceFailures.isEmpty
    }
}

@MainActor
extension DisplayRuntime {
    func beginConsumerTransition(
        affectedSurfaces: [DisplayRuntimeAffectedSurface]
    ) async -> DisplayRuntimeConsumerTransitionBatch {
        var preDisplayIDs: [DisplaySurfaceIdentity: DisplayRuntimeDisplayID?] = [:]
        for surface in affectedSurfaces {
            preDisplayIDs[surface.identity] = surface.preDisplayID
        }
        return await beginConsumerTransition(
            surfaceIdentities: affectedSurfaces.map(\.identity),
            previousDisplayIDs: preDisplayIDs
        )
    }

    func beginConsumerTransition(
        surfaceIdentities: [DisplaySurfaceIdentity],
        previousDisplayIDs: [DisplaySurfaceIdentity: DisplayRuntimeDisplayID?]
    ) async -> DisplayRuntimeConsumerTransitionBatch {
        let affectedSurfaceIdentities = Array(Set(surfaceIdentities)).sorted(by: surfaceSort)
        var transitions: [DisplayRuntimeConsumerTransition] = []
        var epochsBySurface: [DisplaySurfaceIdentity: DisplaySurfaceEpoch] = [:]
        var quiesceFailures: [DisplayRuntimeCaptureIntentApplyResult] = []

        for surfaceIdentity in affectedSurfaceIdentities {
            consumerTransitionBusySurfaces.insert(surfaceIdentity)
            let nextEpoch = currentSurfaceEpoch(for: surfaceIdentity).advanced()
            surfaceEpochs[surfaceIdentity] = nextEpoch
            epochsBySurface[surfaceIdentity] = nextEpoch

            let leases = currentUnreleasedLeases(for: surfaceIdentity)
            for lease in leases {
                let previousDisplayID = lease.resolvedDisplayID ?? previousDisplayIDs[surfaceIdentity] ?? nil
                transitions.append(
                    DisplayRuntimeConsumerTransition(
                        affectedSurface: surfaceIdentity,
                        previousDisplayID: previousDisplayID,
                        leaseID: lease.id,
                        consumerKind: lease.kind,
                        demand: lease.demand,
                        epoch: nextEpoch
                    )
                )
                _ = replaceLease(
                    lease,
                    state: .restarting,
                    surfaceEpoch: nextEpoch,
                    demand: nil,
                    lastFailureCode: nil
                )
            }

            let surfaceTransitions = transitions.filter { $0.affectedSurface == surfaceIdentity }
            guard let previousDisplayID = surfaceTransitions.compactMap(\.previousDisplayID).first else {
                continue
            }
            let drainIntent = submitCaptureIntent(
                surfaceIdentity: surfaceIdentity,
                surfaceEpoch: nextEpoch,
                resolvedDisplayID: previousDisplayID,
                aggregateDemand: nil,
                kind: .drain,
                reason: .transactionQuiesce
            )
            for kind in Set(surfaceTransitions.map(\.consumerKind)).sorted(by: {
                $0.rawValue < $1.rawValue
            }) {
                let result = await applyCaptureIntent(drainIntent, consumerKind: kind)
                guard currentSurfaceEpoch(for: surfaceIdentity) == nextEpoch else {
                    quiesceFailures.append(
                        DisplayRuntimeCaptureIntentApplyResult(
                            revision: drainIntent.revision,
                            outcome: .ignored,
                            failureCode: DisplayRuntimeCaptureIntentFailureCode.epochMismatch
                        )
                    )
                    break
                }
                if result.outcome != .applied {
                    quiesceFailures.append(result)
                }
            }
        }

        return DisplayRuntimeConsumerTransitionBatch(
            affectedSurfaceIdentities: affectedSurfaceIdentities,
            transitions: transitions,
            epochsBySurface: epochsBySurface,
            quiesceFailures: quiesceFailures
        )
    }

    func completeConsumerTransition(
        _ batch: DisplayRuntimeConsumerTransitionBatch,
        snapshot: DisplayRuntimeSnapshot,
        topologyResult: DisplayRuntimeTopologyStabilityResult?,
        releasedSurfaceReasons: [DisplaySurfaceIdentity: String] = [:]
    ) async -> [DisplayRuntimeSessionRestoreResult] {
        var results: [DisplayRuntimeSessionRestoreResult] = []

        surfaceLoop: for surfaceIdentity in batch.affectedSurfaceIdentities {
            defer { consumerTransitionBusySurfaces.remove(surfaceIdentity) }
            var surfaceTransitions = batch.transitions.filter { $0.affectedSurface == surfaceIdentity }
            guard !surfaceTransitions.isEmpty else { continue }
            var hasRestoreFailure = false

            if let releaseReason = releasedSurfaceReasons[surfaceIdentity] {
                for transition in surfaceTransitions {
                    guard let lease = consumerLeasesByID[transition.leaseID] else { continue }
                    _ = replaceLease(
                        lease,
                        state: .released,
                        surfaceEpoch: transition.epoch,
                        demand: nil,
                        lastFailureCode: nil
                    )
                    notifyPreviewLeaseWaitersIfTerminal(leaseID: transition.leaseID)
                }
                for transition in uniqueTransitionsByKind(surfaceTransitions) {
                    results.append(
                        restoreResult(
                            transition: transition,
                            status: .skipped,
                            resolvedDisplayID: nil,
                            failureReason: releaseReason
                        )
                    )
                }
                continue
            }

            let userReleasedTransitions = surfaceTransitions.filter {
                consumerLeasesByID[$0.leaseID]?.state == .released
            }
            for transition in uniqueTransitionsByKind(userReleasedTransitions) {
                results.append(
                    restoreResult(
                        transition: transition,
                        status: .skipped,
                        resolvedDisplayID: nil,
                        failureReason: "consumer_lease_released"
                    )
                )
            }
            surfaceTransitions.removeAll {
                consumerLeasesByID[$0.leaseID]?.state == .released
            }
            guard !surfaceTransitions.isEmpty else { continue }
            let currentSurfaceResultStartIndex = results.endIndex
            let invalidationFailureCode = topologyResult.map {
                "topology_\($0.status.rawValue)"
            } ?? DisplayRuntimeCaptureIntentFailureCode.epochMismatch
            let invalidationStatus: DisplayRuntimeSessionRestoreStatus = topologyResult == nil
                ? .invalidated
                : .failed

            guard currentSurfaceEpoch(for: surfaceIdentity) == surfaceTransitions[0].epoch else {
                results.append(contentsOf: await invalidateConsumerTransition(
                    surfaceTransitions,
                    surfaceIdentity: surfaceIdentity,
                    status: invalidationStatus,
                    failureCode: invalidationFailureCode
                ))
                continue
            }

            guard let resolvedDisplayID = resolvedVisibleDisplayID(
                for: surfaceIdentity,
                snapshot: snapshot
            ) else {
                let failureCode = topologyResult.map {
                    "topology_\($0.status.rawValue)"
                } ?? DisplayRuntimeCaptureIntentFailureCode.displayUnavailable
                surfaceResolvedDisplayIDs.removeValue(forKey: surfaceIdentity)
                for transition in surfaceTransitions {
                    guard let lease = consumerLeasesByID[transition.leaseID] else { continue }
                    _ = replaceLease(
                        lease,
                        state: .failed,
                        surfaceEpoch: transition.epoch,
                        resolvedDisplayID: .some(nil),
                        demand: nil,
                        lastFailureCode: failureCode
                    )
                    notifyPreviewLeaseWaitersIfTerminal(leaseID: transition.leaseID)
                }
                for transition in uniqueTransitionsByKind(surfaceTransitions) {
                    results.append(
                        restoreResult(
                            transition: transition,
                            status: .failed,
                            resolvedDisplayID: nil,
                            failureReason: failureCode
                        )
                    )
                }
                continue
            }

            surfaceResolvedDisplayIDs[surfaceIdentity] = resolvedDisplayID
            for transition in surfaceTransitions {
                guard let lease = consumerLeasesByID[transition.leaseID] else { continue }
                _ = replaceLease(
                    lease,
                    state: .attaching,
                    surfaceEpoch: transition.epoch,
                    resolvedDisplayID: .some(resolvedDisplayID),
                    demand: lease.demand,
                    lastFailureCode: nil
                )
            }

            let restoreIntent = submitCaptureIntent(
                surfaceIdentity: surfaceIdentity,
                reason: .epochChanged
            )
            for transition in uniqueTransitionsByKind(surfaceTransitions) {
                let applyResult = await applyCaptureIntent(
                    restoreIntent,
                    consumerKind: transition.consumerKind
                )
                guard currentSurfaceEpoch(for: surfaceIdentity) == transition.epoch else {
                    results.removeSubrange(currentSurfaceResultStartIndex...)
                    results.append(contentsOf: await invalidateConsumerTransition(
                        surfaceTransitions,
                        surfaceIdentity: surfaceIdentity,
                        status: invalidationStatus,
                        failureCode: invalidationFailureCode
                    ))
                    continue surfaceLoop
                }
                if applyResult.outcome == .applied {
                    let restoredTransitions = surfaceTransitions.filter {
                        $0.consumerKind == transition.consumerKind
                            && consumerLeasesByID[$0.leaseID]?.state == .attaching
                    }
                    guard !restoredTransitions.isEmpty else {
                        results.append(
                            restoreResult(
                                transition: transition,
                                status: .skipped,
                                resolvedDisplayID: nil,
                                failureReason: "consumer_lease_released"
                            )
                        )
                        continue
                    }
                    for restoredTransition in restoredTransitions {
                        guard let lease = consumerLeasesByID[restoredTransition.leaseID] else { continue }
                        _ = replaceLease(
                            lease,
                            state: .attached,
                            demand: lease.demand,
                            lastFailureCode: nil
                        )
                        notifyPreviewLeaseWaitersIfTerminal(leaseID: restoredTransition.leaseID)
                    }
                    results.append(
                        restoreResult(
                            transition: transition,
                            status: .restored,
                            resolvedDisplayID: resolvedDisplayID,
                            failureReason: nil
                        )
                    )
                    continue
                }

                let failureCode = captureIntentFailureCode(for: applyResult)
                let failedTransitions = surfaceTransitions.filter {
                    $0.consumerKind == transition.consumerKind
                        && consumerLeasesByID[$0.leaseID]?.state != .released
                }
                guard !failedTransitions.isEmpty else {
                    results.append(
                        restoreResult(
                            transition: transition,
                            status: .skipped,
                            resolvedDisplayID: nil,
                            failureReason: "consumer_lease_released"
                        )
                    )
                    continue
                }
                for failedTransition in failedTransitions {
                    _ = markConsumerLeaseFailed(
                        leaseID: failedTransition.leaseID,
                        failureCode: failureCode
                    )
                }
                hasRestoreFailure = true
                results.append(
                    restoreResult(
                        transition: transition,
                        status: applyResult.outcome == .ignored ? .invalidated : .failed,
                        resolvedDisplayID: resolvedDisplayID,
                        failureReason: failureCode
                    )
                )
            }
            if hasRestoreFailure {
                let correctiveIntent = submitCaptureIntent(
                    surfaceIdentity: surfaceIdentity,
                    reason: .epochChanged
                )
                for kind in Set(surfaceTransitions.map(\.consumerKind)).sorted(by: {
                    $0.rawValue < $1.rawValue
                }) {
                    _ = await applyCaptureIntent(correctiveIntent, consumerKind: kind)
                }
            }
        }
        return results
    }

    private func invalidateConsumerTransition(
        _ transitions: [DisplayRuntimeConsumerTransition],
        surfaceIdentity: DisplaySurfaceIdentity,
        status: DisplayRuntimeSessionRestoreStatus,
        failureCode: String
    ) async -> [DisplayRuntimeSessionRestoreResult] {
        let currentEpoch = currentSurfaceEpoch(for: surfaceIdentity)
        surfaceResolvedDisplayIDs.removeValue(forKey: surfaceIdentity)

        for transition in transitions {
            guard let lease = consumerLeasesByID[transition.leaseID],
                  lease.state != .released
            else {
                continue
            }
            _ = replaceLease(
                lease,
                state: .failed,
                surfaceEpoch: currentEpoch,
                resolvedDisplayID: .some(nil),
                demand: nil,
                lastFailureCode: failureCode
            )
            notifyPreviewLeaseWaitersIfTerminal(leaseID: transition.leaseID)
        }

        let drainIntent = submitCaptureIntent(
            surfaceIdentity: surfaceIdentity,
            reason: .epochChanged
        )
        for kind in Set(transitions.map(\.consumerKind)).sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            _ = await applyCaptureIntent(drainIntent, consumerKind: kind)
        }

        return uniqueTransitionsByKind(transitions).map { transition in
            restoreResult(
                transition: transition,
                status: status,
                resolvedDisplayID: nil,
                failureReason: failureCode
            )
        }
    }

    func compensateConsumerTransition(
        _ batch: DisplayRuntimeConsumerTransitionBatch
    ) async -> [DisplayRuntimeSessionRestoreResult] {
        await refreshCatalogTopologyForTransaction()
        return await completeConsumerTransition(
            batch,
            snapshot: makeSnapshot(),
            topologyResult: nil
        )
    }

    func compensateConsumerQuiesceFailure(
        _ batch: DisplayRuntimeConsumerTransitionBatch,
        transactionID: DisplayRuntimeTransactionID
    ) async -> [DisplayRuntimeSessionRestoreResult] {
        let restoreResults = await compensateConsumerTransition(batch)
        updateTrace(transactionID) { trace in
            trace.replacing(restoreResults: restoreResults)
        }
        return restoreResults
    }

    private func uniqueTransitionsByKind(
        _ transitions: [DisplayRuntimeConsumerTransition]
    ) -> [DisplayRuntimeConsumerTransition] {
        var firstByKind: [DisplaySurfaceConsumerKind: DisplayRuntimeConsumerTransition] = [:]
        for transition in transitions {
            firstByKind[transition.consumerKind] = firstByKind[transition.consumerKind] ?? transition
        }
        return firstByKind.values.sorted { $0.consumerKind.rawValue < $1.consumerKind.rawValue }
    }

    private func restoreResult(
        transition: DisplayRuntimeConsumerTransition,
        status: DisplayRuntimeSessionRestoreStatus,
        resolvedDisplayID: DisplayRuntimeDisplayID?,
        failureReason: String?
    ) -> DisplayRuntimeSessionRestoreResult {
        DisplayRuntimeSessionRestoreResult(
            kind: transition.consumerKind == .preview ? .preview : .sharing,
            status: status,
            previousDisplayID: transition.previousDisplayID,
            resolvedDisplayID: resolvedDisplayID,
            failureReason: failureReason
        )
    }

    private func surfaceSort(
        lhs: DisplaySurfaceIdentity,
        rhs: DisplaySurfaceIdentity
    ) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.stableID < rhs.stableID
    }
}
