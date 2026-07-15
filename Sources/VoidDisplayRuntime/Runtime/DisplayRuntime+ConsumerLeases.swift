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

    package func currentConsumerLeaseSnapshot() -> [DisplayRuntimeConsumerLease] {
        consumerLeasesByID.values.sorted(by: leaseSort)
    }

    package func currentAggregatedDemandSnapshot() -> [DisplayRuntimeAggregatedDemand] {
        Set(consumerLeasesByID.values.map(\.surfaceIdentity))
            .compactMap { aggregateDemand(for: $0, surfaces: nil) }
            .sorted(by: aggregateDemandSort)
    }

    package func currentAggregatedDemandSnapshot(
        surfaces: [DisplaySurface]
    ) -> [DisplayRuntimeAggregatedDemand] {
        Set(consumerLeasesByID.values.map(\.surfaceIdentity))
            .compactMap { aggregateDemand(for: $0, surfaces: surfaces) }
            .sorted(by: aggregateDemandSort)
    }

    package func currentEffectiveCaptureIntentSnapshot() -> [DisplayRuntimeEffectiveCaptureIntent] {
        effectiveCaptureIntentsBySurface.values.sorted {
            captureIntentSort(lhs: $0.intent, rhs: $1.intent)
        }
    }

    package func currentSurfaceEpochSnapshot() -> [DisplayRuntimeSurfaceEpochSnapshot] {
        Set(
            consumerLeasesByID.values.map(\.surfaceIdentity)
                + Array(effectiveCaptureIntentsBySurface.keys)
                + Array(surfaceEpochs.keys)
        )
        .map {
            DisplayRuntimeSurfaceEpochSnapshot(
                surfaceIdentity: $0,
                surfaceEpoch: currentSurfaceEpoch(for: $0)
            )
        }
        .sorted {
            if $0.surfaceIdentity.kind != $1.surfaceIdentity.kind {
                return $0.surfaceIdentity.kind.rawValue < $1.surfaceIdentity.kind.rawValue
            }
            return $0.surfaceIdentity.stableID < $1.surfaceIdentity.stableID
        }
    }

    package func currentLatestCaptureIntentRevision() -> DisplayRuntimeCaptureIntentRevision? {
        captureIntentsByRevision.keys.max()
    }

    package func currentSurfaceEpoch(
        for surfaceIdentity: DisplaySurfaceIdentity
    ) -> DisplaySurfaceEpoch {
        surfaceEpochs[surfaceIdentity] ?? .initial
    }

    @discardableResult
    package func advanceSurfaceEpoch(
        surfaceIdentity: DisplaySurfaceIdentity,
        resolvedDisplayID: DisplayRuntimeDisplayID? = nil
    ) -> DisplaySurfaceEpoch {
        let nextEpoch = currentSurfaceEpoch(for: surfaceIdentity).advanced()
        surfaceEpochs[surfaceIdentity] = nextEpoch
        if let resolvedDisplayID {
            surfaceResolvedDisplayIDs[surfaceIdentity] = resolvedDisplayID
        } else {
            surfaceResolvedDisplayIDs.removeValue(forKey: surfaceIdentity)
        }

        for lease in currentDemandLeases(for: surfaceIdentity) where lease.surfaceEpoch != nextEpoch {
            _ = replaceLease(
                lease,
                state: .restarting,
                surfaceEpoch: nextEpoch,
                demand: nil,
                lastFailureCode: DisplayRuntimeCaptureIntentFailureCode.epochMismatch
            )
        }
        _ = submitCaptureIntent(surfaceIdentity: surfaceIdentity, reason: .epochChanged)
        return nextEpoch
    }

    @discardableResult
    package func recordCaptureIntentApplyResult(
        _ result: DisplayRuntimeCaptureIntentApplyResult
    ) -> DisplayRuntimeCaptureIntentApplyResult {
        guard let intent = captureIntentsByRevision[result.revision],
              let currentEffectiveIntent = effectiveCaptureIntentsBySurface[intent.surfaceIdentity],
              currentEffectiveIntent.intent.revision == result.revision
        else {
            let ignoredResult = result.ignored()
            captureIntentApplyResultsByRevision[ignoredResult.revision] = ignoredResult
            return ignoredResult
        }

        let acceptedResult = result.outcome == .ignored ? result.ignored() : result
        captureIntentApplyResultsByRevision[acceptedResult.revision] = acceptedResult
        let failureCode = acceptedResult.outcome == .failed ? acceptedResult.failureCode : nil
        effectiveCaptureIntentsBySurface[intent.surfaceIdentity] = DisplayRuntimeEffectiveCaptureIntent(
            intent: intent,
            lastApplyResult: acceptedResult,
            lastFailureCode: failureCode
        )
        return acceptedResult
    }

    package func captureIntentApplyResult(
        for revision: DisplayRuntimeCaptureIntentRevision
    ) -> DisplayRuntimeCaptureIntentApplyResult? {
        captureIntentApplyResultsByRevision[revision]
    }

    func aggregateDemand(
        for surfaceIdentity: DisplaySurfaceIdentity,
        surfaces: [DisplaySurface]?
    ) -> DisplayRuntimeAggregatedDemand? {
        DisplayRuntimeConsumerDemandAggregator.aggregate(
            surfaceIdentity: surfaceIdentity,
            surfaceEpoch: currentSurfaceEpoch(for: surfaceIdentity),
            resolvedDisplayID: resolvedDisplayID(for: surfaceIdentity, surfaces: surfaces),
            leases: Array(consumerLeasesByID.values)
        )
    }

    @discardableResult
    func submitCaptureIntent(
        surfaceIdentity: DisplaySurfaceIdentity,
        reason: DisplayRuntimeCaptureIntentReason
    ) -> DisplayRuntimeCaptureIntent {
        let aggregateDemand = aggregateDemand(for: surfaceIdentity, surfaces: nil)
        return submitCaptureIntent(
            surfaceIdentity: surfaceIdentity,
            surfaceEpoch: currentSurfaceEpoch(for: surfaceIdentity),
            resolvedDisplayID: resolvedDisplayID(for: surfaceIdentity, surfaces: nil),
            aggregateDemand: aggregateDemand,
            kind: aggregateDemand == nil ? .drain : .capture,
            reason: reason
        )
    }

    @discardableResult
    func submitCaptureIntent(
        surfaceIdentity: DisplaySurfaceIdentity,
        surfaceEpoch: DisplaySurfaceEpoch,
        resolvedDisplayID: DisplayRuntimeDisplayID?,
        aggregateDemand: DisplayRuntimeAggregatedDemand?,
        kind: DisplayRuntimeCaptureIntentKind,
        reason: DisplayRuntimeCaptureIntentReason
    ) -> DisplayRuntimeCaptureIntent {
        captureIntentRevisionCounter += 1
        let intent = DisplayRuntimeCaptureIntent(
            surfaceIdentity: surfaceIdentity,
            surfaceEpoch: surfaceEpoch,
            resolvedDisplayID: resolvedDisplayID,
            aggregateDemand: aggregateDemand,
            kind: kind,
            reason: reason,
            revision: DisplayRuntimeCaptureIntentRevision(rawValue: captureIntentRevisionCounter)
        )
        captureIntentsByRevision[intent.revision] = intent
        effectiveCaptureIntentsBySurface[surfaceIdentity] = DisplayRuntimeEffectiveCaptureIntent(intent: intent)
        return intent
    }

    func applyCaptureIntent(
        _ intent: DisplayRuntimeCaptureIntent,
        consumerKind: DisplaySurfaceConsumerKind
    ) async -> DisplayRuntimeCaptureIntentApplyResult {
        let key = DisplayRuntimeCaptureIntentApplyKey(
            surfaceIdentity: intent.surfaceIdentity,
            consumerKind: consumerKind
        )
        let tailID = UUID()
        let previousTask = captureIntentApplyTails[key]?.task
        let task = Task { @MainActor [weak self] in
            if let previousTask {
                _ = await previousTask.value
            }
            guard let self else {
                return DisplayRuntimeCaptureIntentApplyResult.failed(
                    revision: intent.revision,
                    failureCode: DisplayRuntimeCaptureIntentFailureCode.adapterUnavailable
                )
            }
            defer {
                if self.captureIntentApplyTails[key]?.id == tailID {
                    self.captureIntentApplyTails.removeValue(forKey: key)
                }
            }
            guard self.effectiveCaptureIntentsBySurface[intent.surfaceIdentity]?.intent.revision
                    == intent.revision
            else {
                return self.recordCaptureIntentApplyResult(
                    DisplayRuntimeCaptureIntentApplyResult(
                        revision: intent.revision,
                        outcome: .ignored,
                        failureCode: DisplayRuntimeCaptureIntentFailureCode.applyInvalidated
                    )
                )
            }
            return await self.applyCurrentCaptureIntent(intent, consumerKind: consumerKind)
        }
        captureIntentApplyTails[key] = DisplayRuntimeCaptureIntentApplyTail(
            id: tailID,
            task: task
        )
        return await task.value
    }

    private func applyCurrentCaptureIntent(
        _ intent: DisplayRuntimeCaptureIntent,
        consumerKind: DisplaySurfaceConsumerKind
    ) async -> DisplayRuntimeCaptureIntentApplyResult {
        let rawResult: DisplayRuntimeCaptureIntentApplyResult
        if let captureIntentCommander {
            switch consumerKind {
            case .preview:
                rawResult = await captureIntentCommander.applyPreviewCaptureIntent(intent)
            case .lanWebView:
                rawResult = await captureIntentCommander.applyLANWebViewCaptureIntent(intent)
            }
        } else {
            rawResult = .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.adapterUnavailable
            )
        }
        return recordCaptureIntentApplyResult(rawResult)
    }

    func captureIntentFailureCode(
        for result: DisplayRuntimeCaptureIntentApplyResult
    ) -> String {
        result.failureCode ?? (result.outcome == .ignored
            ? DisplayRuntimeCaptureIntentFailureCode.applyInvalidated
            : DisplayRuntimeCaptureIntentFailureCode.applyFailed)
    }

    private func shouldCompensateCaptureIntent(
        _ intent: DisplayRuntimeCaptureIntent,
        after result: DisplayRuntimeCaptureIntentApplyResult
    ) -> Bool {
        guard result.outcome != .applied else { return false }
        return effectiveCaptureIntentsBySurface[intent.surfaceIdentity]?.intent.revision
            == intent.revision
    }

    private func failLeaseIfCurrentCompensationDidNotApply(
        leaseID: DisplayRuntimeConsumerLeaseID,
        intent: DisplayRuntimeCaptureIntent,
        applyResult: DisplayRuntimeCaptureIntentApplyResult,
        consumerKind: DisplaySurfaceConsumerKind
    ) async {
        guard shouldCompensateCaptureIntent(intent, after: applyResult),
              let failedLease = markConsumerLeaseFailed(
                leaseID: leaseID,
                failureCode: captureIntentFailureCode(for: applyResult)
              )
        else {
            return
        }
        let drainIntent = submitCaptureIntent(
            surfaceIdentity: failedLease.surfaceIdentity,
            reason: .detach
        )
        _ = await applyCaptureIntent(drainIntent, consumerKind: consumerKind)
    }

    func currentDemandLeases(
        for surfaceIdentity: DisplaySurfaceIdentity
    ) -> [DisplayRuntimeConsumerLease] {
        consumerLeasesByID.values
            .filter { $0.surfaceIdentity == surfaceIdentity }
            .filter { $0.state.contributesDemand }
            .sorted(by: leaseSort)
    }

    func currentUnreleasedLeases(
        for surfaceIdentity: DisplaySurfaceIdentity
    ) -> [DisplayRuntimeConsumerLease] {
        consumerLeasesByID.values
            .filter { $0.surfaceIdentity == surfaceIdentity }
            .filter { $0.state != .released }
            .sorted(by: leaseSort)
    }

    func resolvedDisplayID(
        for surfaceIdentity: DisplaySurfaceIdentity,
        surfaces: [DisplaySurface]?
    ) -> DisplayRuntimeDisplayID? {
        if let storedDisplayID = surfaceResolvedDisplayIDs[surfaceIdentity] {
            return storedDisplayID
        }
        if let surfaces {
            return surfaces.first {
                $0.identity == surfaceIdentity
            }?.currentDisplayID
        }
        return makeSnapshot().surfaces.first {
            $0.identity == surfaceIdentity
        }?.currentDisplayID
    }

    func resolvedVisibleDisplayID(
        for surfaceIdentity: DisplaySurfaceIdentity,
        snapshot: DisplayRuntimeSnapshot
    ) -> DisplayRuntimeDisplayID? {
        let visibleDisplayIDs = Set(snapshot.catalog.loadedDisplays.map(\.displayID))
        guard let surface = snapshot.surfaces.first(where: { $0.identity == surfaceIdentity }),
              let displayID = surface.currentDisplayID,
              surface.managedVirtualDisplay?.isRunning != false,
              visibleDisplayIDs.contains(displayID)
        else {
            return nil
        }
        return displayID
    }

    @discardableResult
    func replaceLease(
        _ lease: DisplayRuntimeConsumerLease,
        state: DisplayRuntimeConsumerLeaseState,
        surfaceEpoch: DisplaySurfaceEpoch? = nil,
        resolvedDisplayID: DisplayRuntimeDisplayID?? = nil,
        demand: DisplayRuntimeConsumerDemand?,
        lastFailureCode: String?
    ) -> DisplayRuntimeConsumerLease {
        let now = Date.now
        let updatedAt = now > lease.updatedAt
            ? now
            : lease.updatedAt.addingTimeInterval(0.000_001)
        let updatedLease = DisplayRuntimeConsumerLease(
            id: lease.id,
            surfaceIdentity: lease.surfaceIdentity,
            surfaceEpoch: surfaceEpoch ?? lease.surfaceEpoch,
            resolvedDisplayID: resolvedDisplayID ?? lease.resolvedDisplayID,
            kind: lease.kind,
            owner: lease.owner,
            createdAt: lease.createdAt,
            updatedAt: updatedAt,
            state: state,
            demand: demand ?? lease.demand,
            lastFailureCode: lastFailureCode
        )
        consumerLeasesByID[lease.id] = updatedLease
        return updatedLease
    }

    @discardableResult
    func markConsumerLeaseFailed(
        leaseID: DisplayRuntimeConsumerLeaseID,
        failureCode: String
    ) -> DisplayRuntimeConsumerLease? {
        guard let lease = consumerLeasesByID[leaseID], lease.state != .released else { return nil }
        let failedLease = replaceLease(
            lease,
            state: .failed,
            demand: nil,
            lastFailureCode: failureCode
        )
        notifyPreviewLeaseWaitersIfTerminal(leaseID: leaseID)
        return failedLease
    }

    func notifyPreviewLeaseWaitersIfTerminal(
        leaseID: DisplayRuntimeConsumerLeaseID
    ) {
        guard let lease = terminalPreviewLease(leaseID: leaseID),
              let waiters = previewLeaseWaiters.removeValue(forKey: leaseID)
        else {
            return
        }
        for continuation in waiters.values {
            continuation.resume(returning: lease)
        }
    }

    private func terminalPreviewLease(
        leaseID: DisplayRuntimeConsumerLeaseID
    ) -> DisplayRuntimeConsumerLease? {
        guard let lease = consumerLeasesByID[leaseID] else { return nil }
        switch lease.state {
        case .attached, .failed, .released:
            return lease
        case .attaching, .restarting, .draining:
            return nil
        }
    }

    private func cancelPreviewLeaseWaiter(
        leaseID: DisplayRuntimeConsumerLeaseID,
        waiterID: UUID
    ) {
        guard let continuation = previewLeaseWaiters[leaseID]?.removeValue(forKey: waiterID) else {
            return
        }
        if previewLeaseWaiters[leaseID]?.isEmpty == true {
            previewLeaseWaiters.removeValue(forKey: leaseID)
        }
        continuation.resume(returning: consumerLeasesByID[leaseID])
    }

    private func leaseSort(
        lhs: DisplayRuntimeConsumerLease,
        rhs: DisplayRuntimeConsumerLease
    ) -> Bool {
        if lhs.surfaceIdentity.kind != rhs.surfaceIdentity.kind {
            return lhs.surfaceIdentity.kind.rawValue < rhs.surfaceIdentity.kind.rawValue
        }
        if lhs.surfaceIdentity.stableID != rhs.surfaceIdentity.stableID {
            return lhs.surfaceIdentity.stableID < rhs.surfaceIdentity.stableID
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }

    private func aggregateDemandSort(
        lhs: DisplayRuntimeAggregatedDemand,
        rhs: DisplayRuntimeAggregatedDemand
    ) -> Bool {
        if lhs.surfaceIdentity.kind != rhs.surfaceIdentity.kind {
            return lhs.surfaceIdentity.kind.rawValue < rhs.surfaceIdentity.kind.rawValue
        }
        return lhs.surfaceIdentity.stableID < rhs.surfaceIdentity.stableID
    }

    private func captureIntentSort(
        lhs: DisplayRuntimeCaptureIntent,
        rhs: DisplayRuntimeCaptureIntent
    ) -> Bool {
        if lhs.surfaceIdentity.kind != rhs.surfaceIdentity.kind {
            return lhs.surfaceIdentity.kind.rawValue < rhs.surfaceIdentity.kind.rawValue
        }
        if lhs.surfaceIdentity.stableID != rhs.surfaceIdentity.stableID {
            return lhs.surfaceIdentity.stableID < rhs.surfaceIdentity.stableID
        }
        return lhs.revision < rhs.revision
    }
}
