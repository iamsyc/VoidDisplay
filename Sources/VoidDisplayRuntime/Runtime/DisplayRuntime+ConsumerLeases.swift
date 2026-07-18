import Foundation

@MainActor
extension DisplayRuntime {
    package func attachPreviewConsumer(
        surfaceIdentity: DisplaySurfaceIdentity,
        owner: DisplayRuntimeConsumerOwner,
        demand: DisplayRuntimeConsumerDemand
    ) async -> DisplayRuntimeConsumerAttachOutcome {
        await attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: owner,
            demand: demand
        )
    }

    package func attachLANWebViewConsumer(
        surfaceIdentity: DisplaySurfaceIdentity,
        owner: DisplayRuntimeConsumerOwner,
        demand: DisplayRuntimeConsumerDemand
    ) async -> DisplayRuntimeConsumerAttachOutcome {
        await attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .lanWebView,
            owner: owner,
            demand: demand
        )
    }

    private func attachConsumer(
        surfaceIdentity: DisplaySurfaceIdentity,
        kind: DisplaySurfaceConsumerKind,
        owner: DisplayRuntimeConsumerOwner,
        demand: DisplayRuntimeConsumerDemand
    ) async -> DisplayRuntimeConsumerAttachOutcome {
        guard !consumerTransitionBusySurfaces.contains(surfaceIdentity) else {
            return .rejected(
                failureCode: DisplayRuntimeCaptureIntentFailureCode.consumerLeaseRestarting
            )
        }

        let lease: DisplayRuntimeConsumerLease
        if let existingLease = currentUnreleasedLeases(for: surfaceIdentity)
            .first(where: { $0.kind == kind }) {
            guard existingLease.state == .attached else {
                return .rejected(
                    failureCode: existingLease.state == .restarting
                        ? DisplayRuntimeCaptureIntentFailureCode.consumerLeaseRestarting
                        : DisplayRuntimeCaptureIntentFailureCode.consumerLeaseAlreadyExists
                )
            }
            if existingLease.demand.hasSameCaptureRequirements(as: demand),
               let applyResult = metadataOnlyCaptureIntentApplyResult(for: surfaceIdentity) {
                let updatedLease = replaceLease(
                    existingLease,
                    state: .attached,
                    demand: demand,
                    lastFailureCode: nil
                )
                return .attached(lease: updatedLease, applyResult: applyResult)
            }
            lease = replaceLease(
                existingLease,
                state: .attaching,
                demand: demand,
                lastFailureCode: nil
            )
        } else {
            let now = Date.now
            lease = DisplayRuntimeConsumerLease(
                surfaceIdentity: surfaceIdentity,
                surfaceEpoch: currentSurfaceEpoch(for: surfaceIdentity),
                resolvedDisplayID: resolvedDisplayID(for: surfaceIdentity, surfaces: nil),
                kind: kind,
                owner: owner,
                createdAt: now,
                updatedAt: now,
                state: .attaching,
                demand: demand
            )
            consumerLeasesByID[lease.id] = lease
        }

        let intent = submitCaptureIntent(surfaceIdentity: surfaceIdentity, reason: .attach)
        let applyResult = await applyCaptureIntent(intent, consumerKind: kind)
        if let currentLease = consumerLeasesByID[lease.id], currentLease.state == .attaching {
            if applyResult.outcome == .applied {
                _ = replaceLease(
                    currentLease,
                    state: .attached,
                    demand: currentLease.demand,
                    lastFailureCode: nil
                )
            } else {
                _ = markConsumerLeaseFailed(
                    leaseID: lease.id,
                    failureCode: captureIntentFailureCode(for: applyResult)
                )
                let correctiveIntent = submitCaptureIntent(
                    surfaceIdentity: surfaceIdentity,
                    reason: .detach
                )
                _ = await applyCaptureIntent(correctiveIntent, consumerKind: kind)
            }
        }
        return .attached(
            lease: consumerLeasesByID[lease.id] ?? lease,
            applyResult: applyResult
        )
    }

    @discardableResult
    package func updatePreviewConsumerDemand(
        leaseID: DisplayRuntimeConsumerLeaseID,
        demand: DisplayRuntimeConsumerDemand
    ) async -> DisplayRuntimeCaptureIntentApplyResult? {
        guard let lease = consumerLeasesByID[leaseID],
              lease.kind == .preview,
              lease.state == .attached,
              !consumerTransitionBusySurfaces.contains(lease.surfaceIdentity)
        else {
            return nil
        }
        _ = replaceLease(lease, state: .attached, demand: demand, lastFailureCode: nil)
        let intent = submitCaptureIntent(surfaceIdentity: lease.surfaceIdentity, reason: .attach)
        let applyResult = await applyCaptureIntent(intent, consumerKind: .preview)
        if shouldCompensateCaptureIntent(intent, after: applyResult),
           consumerLeasesByID[leaseID]?.demand == demand {
            _ = replaceLease(
                consumerLeasesByID[leaseID] ?? lease,
                state: .attached,
                demand: lease.demand,
                lastFailureCode: captureIntentFailureCode(for: applyResult)
            )
            let correctiveIntent = submitCaptureIntent(
                surfaceIdentity: lease.surfaceIdentity,
                reason: .attach
            )
            let correctiveResult = await applyCaptureIntent(correctiveIntent, consumerKind: .preview)
            await failLeaseIfCurrentCompensationDidNotApply(
                leaseID: leaseID,
                intent: correctiveIntent,
                applyResult: correctiveResult,
                consumerKind: .preview
            )
        }
        return applyResult
    }

    @discardableResult
    package func updateLANWebViewConsumerDemand(
        surfaceIdentity: DisplaySurfaceIdentity,
        demand: DisplayRuntimeConsumerDemand
    ) async -> DisplayRuntimeCaptureIntentApplyResult? {
        guard let lease = currentDemandLeases(for: surfaceIdentity)
            .first(where: { $0.kind == .lanWebView }),
              lease.state == .attached,
              !consumerTransitionBusySurfaces.contains(surfaceIdentity)
        else {
            return nil
        }
        if lease.demand.hasSameCaptureRequirements(as: demand),
           let applyResult = metadataOnlyCaptureIntentApplyResult(for: surfaceIdentity) {
            _ = replaceLease(lease, state: .attached, demand: demand, lastFailureCode: nil)
            return applyResult
        }
        _ = replaceLease(lease, state: .attached, demand: demand, lastFailureCode: nil)
        let intent = submitCaptureIntent(surfaceIdentity: surfaceIdentity, reason: .attach)
        let applyResult = await applyCaptureIntent(intent, consumerKind: .lanWebView)
        if shouldCompensateCaptureIntent(intent, after: applyResult),
           consumerLeasesByID[lease.id]?.demand == demand {
            _ = replaceLease(
                consumerLeasesByID[lease.id] ?? lease,
                state: .attached,
                demand: lease.demand,
                lastFailureCode: captureIntentFailureCode(for: applyResult)
            )
            let correctiveIntent = submitCaptureIntent(
                surfaceIdentity: surfaceIdentity,
                reason: .attach
            )
            let correctiveResult = await applyCaptureIntent(correctiveIntent, consumerKind: .lanWebView)
            await failLeaseIfCurrentCompensationDidNotApply(
                leaseID: lease.id,
                intent: correctiveIntent,
                applyResult: correctiveResult,
                consumerKind: .lanWebView
            )
        }
        return applyResult
    }

    package func updateConsumerPowerProfile(
        _ powerProfile: DisplayRuntimeCapturePowerProfile
    ) async {
        let unreleasedLeases = consumerLeasesByID.values.filter { $0.state != .released }
        for lease in unreleasedLeases {
            _ = replaceLease(
                lease,
                state: lease.state,
                demand: lease.demand.replacing(powerProfile: powerProfile),
                lastFailureCode: lease.lastFailureCode
            )
        }

        let attachedLeases = unreleasedLeases.filter { $0.state == .attached }
        for surfaceIdentity in Set(attachedLeases.map(\.surfaceIdentity)) {
            let intent = submitCaptureIntent(
                surfaceIdentity: surfaceIdentity,
                reason: .performanceModeChanged
            )
            let kinds = Set(currentDemandLeases(for: surfaceIdentity).map(\.kind))
            for kind in kinds.sorted(by: { $0.rawValue < $1.rawValue }) {
                _ = await applyCaptureIntent(intent, consumerKind: kind)
            }
        }
    }

    @discardableResult
    package func detachPreviewConsumer(
        leaseID: DisplayRuntimeConsumerLeaseID
    ) async -> DisplayRuntimePreviewConsumerDetachResult {
        guard let lease = consumerLeasesByID[leaseID], lease.kind == .preview else {
            return DisplayRuntimePreviewConsumerDetachResult(
                releasedLease: nil,
                applyResult: nil
            )
        }
        if lease.state == .released {
            return DisplayRuntimePreviewConsumerDetachResult(
                releasedLease: lease,
                applyResult: nil
            )
        }

        let releasedLease = replaceLease(
            lease,
            state: .released,
            demand: nil,
            lastFailureCode: nil
        )
        notifyPreviewLeaseWaitersIfTerminal(leaseID: leaseID)
        let intent = submitCaptureIntent(
            surfaceIdentity: releasedLease.surfaceIdentity,
            reason: .detach
        )
        let applyResult = await applyCaptureIntent(intent, consumerKind: .preview)
        return DisplayRuntimePreviewConsumerDetachResult(
            releasedLease: releasedLease,
            applyResult: applyResult
        )
    }

    @discardableResult
    package func detachLANWebViewConsumer(
        surfaceIdentity: DisplaySurfaceIdentity
    ) async -> DisplayRuntimeLANWebViewConsumerDetachResult {
        guard let lease = currentUnreleasedLeases(for: surfaceIdentity)
            .first(where: { $0.kind == .lanWebView })
        else {
            return DisplayRuntimeLANWebViewConsumerDetachResult(
                releasedLease: nil,
                applyResult: nil
            )
        }
        if lease.state == .released {
            return DisplayRuntimeLANWebViewConsumerDetachResult(
                releasedLease: lease,
                applyResult: nil
            )
        }

        let releasedLease = replaceLease(
            lease,
            state: .released,
            demand: nil,
            lastFailureCode: nil
        )
        let intent = submitCaptureIntent(
            surfaceIdentity: releasedLease.surfaceIdentity,
            reason: .detach
        )
        let applyResult = await applyCaptureIntent(intent, consumerKind: .lanWebView)
        return DisplayRuntimeLANWebViewConsumerDetachResult(
            releasedLease: releasedLease,
            applyResult: applyResult
        )
    }

    package func retryPreviewConsumer(
        leaseID: DisplayRuntimeConsumerLeaseID
    ) async -> DisplayRuntimeConsumerLease? {
        guard let lease = consumerLeasesByID[leaseID],
              lease.kind == .preview,
              lease.state != .released,
              !consumerTransitionBusySurfaces.contains(lease.surfaceIdentity)
        else {
            return consumerLeasesByID[leaseID]
        }

        consumerTransitionBusySurfaces.insert(lease.surfaceIdentity)
        defer { consumerTransitionBusySurfaces.remove(lease.surfaceIdentity) }
        let nextEpoch = currentSurfaceEpoch(for: lease.surfaceIdentity).advanced()
        surfaceEpochs[lease.surfaceIdentity] = nextEpoch
        _ = replaceLease(
            lease,
            state: .restarting,
            surfaceEpoch: nextEpoch,
            demand: nil,
            lastFailureCode: nil
        )
        await refreshCatalogTopologyForTransaction()
        let snapshot = makeSnapshot()
        guard consumerLeasesByID[leaseID]?.state != .released else {
            notifyPreviewLeaseWaitersIfTerminal(leaseID: leaseID)
            return consumerLeasesByID[leaseID]
        }
        let displayID = resolvedVisibleDisplayID(
            for: lease.surfaceIdentity,
            snapshot: snapshot
        )
        guard let displayID else {
            _ = replaceLease(
                consumerLeasesByID[leaseID] ?? lease,
                state: .failed,
                surfaceEpoch: nextEpoch,
                resolvedDisplayID: .some(nil),
                demand: nil,
                lastFailureCode: DisplayRuntimeCaptureIntentFailureCode.displayUnavailable
            )
            notifyPreviewLeaseWaitersIfTerminal(leaseID: leaseID)
            return consumerLeasesByID[leaseID]
        }

        surfaceResolvedDisplayIDs[lease.surfaceIdentity] = displayID
        _ = replaceLease(
            consumerLeasesByID[leaseID] ?? lease,
            state: .attaching,
            surfaceEpoch: nextEpoch,
            resolvedDisplayID: .some(displayID),
            demand: nil,
            lastFailureCode: nil
        )
        let intent = submitCaptureIntent(surfaceIdentity: lease.surfaceIdentity, reason: .retry)
        let applyResult = await applyCaptureIntent(intent, consumerKind: .preview)
        if let currentLease = consumerLeasesByID[leaseID], currentLease.state == .attaching {
            if applyResult.outcome == .applied {
                _ = replaceLease(
                    currentLease,
                    state: .attached,
                    demand: currentLease.demand,
                    lastFailureCode: nil
                )
            } else {
                _ = markConsumerLeaseFailed(
                    leaseID: leaseID,
                    failureCode: captureIntentFailureCode(for: applyResult)
                )
                let correctiveIntent = submitCaptureIntent(
                    surfaceIdentity: lease.surfaceIdentity,
                    reason: .detach
                )
                _ = await applyCaptureIntent(correctiveIntent, consumerKind: .preview)
            }
        }
        notifyPreviewLeaseWaitersIfTerminal(leaseID: leaseID)
        return consumerLeasesByID[leaseID]
    }

    package func consumerLease(
        leaseID: DisplayRuntimeConsumerLeaseID
    ) -> DisplayRuntimeConsumerLease? {
        consumerLeasesByID[leaseID]
    }

    package func isConsumerTransitionBusy(
        surfaceIdentity: DisplaySurfaceIdentity
    ) -> Bool {
        consumerTransitionBusySurfaces.contains(surfaceIdentity)
    }

    package func waitForPreviewConsumerResolution(
        leaseID: DisplayRuntimeConsumerLeaseID
    ) async -> DisplayRuntimeConsumerLease? {
        if let lease = terminalPreviewLease(leaseID: leaseID) {
            return lease
        }
        guard consumerLeasesByID[leaseID] != nil else { return nil }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let lease = terminalPreviewLease(leaseID: leaseID) {
                    continuation.resume(returning: lease)
                    return
                }
                previewLeaseWaiters[leaseID, default: [:]][waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPreviewLeaseWaiter(leaseID: leaseID, waiterID: waiterID)
            }
        }
    }

}
