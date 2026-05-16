import Foundation

@MainActor
extension DisplayRuntime {
    package func attachConsumer(
        surfaceIdentity: DisplaySurfaceIdentity,
        kind: DisplaySurfaceConsumerKind,
        owner: DisplayRuntimeConsumerOwner,
        demand: DisplayRuntimeConsumerDemand
    ) -> DisplayRuntimeConsumerLease {
        attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: kind,
            owner: owner,
            demand: demand,
            submitsCaptureIntent: true
        )
    }

    package func attachPreviewConsumer(
        surfaceIdentity: DisplaySurfaceIdentity,
        owner: DisplayRuntimeConsumerOwner,
        demand: DisplayRuntimeConsumerDemand
    ) async -> DisplayRuntimePreviewConsumerAttachResult {
        let lease = attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: owner,
            demand: demand,
            submitsCaptureIntent: false
        )
        let intent = submitCaptureIntent(
            surfaceIdentity: surfaceIdentity,
            reason: .attach,
            appliesCommand: false
        )
        let rawResult: DisplayRuntimeCaptureIntentApplyResult
        if let captureIntentCommander {
            rawResult = await captureIntentCommander.applyPreviewCaptureIntent(intent)
        } else {
            rawResult = .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.adapterUnavailable
            )
        }
        return DisplayRuntimePreviewConsumerAttachResult(
            lease: lease,
            applyResult: recordCaptureIntentApplyResult(rawResult)
        )
    }

    package func attachLANWebViewConsumer(
        surfaceIdentity: DisplaySurfaceIdentity,
        owner: DisplayRuntimeConsumerOwner,
        demand: DisplayRuntimeConsumerDemand
    ) async -> DisplayRuntimeLANWebViewConsumerAttachResult {
        let hadExistingLease = currentDemandLeases(for: surfaceIdentity)
            .contains { $0.kind == .lanWebView }
        let lease = attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .lanWebView,
            owner: owner,
            demand: demand,
            submitsCaptureIntent: false
        )
        guard !hadExistingLease else {
            return DisplayRuntimeLANWebViewConsumerAttachResult(
                lease: lease,
                applyResult: nil
            )
        }

        let intent = submitCaptureIntent(
            surfaceIdentity: surfaceIdentity,
            reason: .attach,
            appliesCommand: false
        )
        let rawResult: DisplayRuntimeCaptureIntentApplyResult
        if let captureIntentCommander {
            rawResult = await captureIntentCommander.applyLANWebViewCaptureIntent(intent)
        } else {
            rawResult = .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.adapterUnavailable
            )
        }
        return DisplayRuntimeLANWebViewConsumerAttachResult(
            lease: lease,
            applyResult: recordCaptureIntentApplyResult(rawResult)
        )
    }

    package func attachDiagnosticsRecorderConsumer(
        surfaceIdentity: DisplaySurfaceIdentity,
        owner: DisplayRuntimeConsumerOwner,
        demand: DisplayRuntimeConsumerDemand
    ) async -> DisplayRuntimeDiagnosticsRecorderAttachResult {
        let lease = attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .diagnosticsRecorder,
            owner: owner,
            demand: demand,
            submitsCaptureIntent: false
        )
        let intent = submitCaptureIntent(
            surfaceIdentity: surfaceIdentity,
            reason: .attach,
            appliesCommand: false
        )
        let rawResult: DisplayRuntimeCaptureIntentApplyResult
        if let captureIntentCommander {
            rawResult = await captureIntentCommander.applyDiagnosticsRecorderCaptureIntent(intent)
        } else {
            rawResult = .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.adapterUnavailable
            )
        }
        return DisplayRuntimeDiagnosticsRecorderAttachResult(
            lease: lease,
            applyResult: recordCaptureIntentApplyResult(rawResult)
        )
    }

    @discardableResult
    package func updateLANWebViewConsumerDemand(
        surfaceIdentity: DisplaySurfaceIdentity,
        demand: DisplayRuntimeConsumerDemand
    ) -> DisplayRuntimeConsumerLease? {
        guard let existingLease = currentDemandLeases(for: surfaceIdentity)
            .first(where: { $0.kind == .lanWebView })
        else {
            return nil
        }
        let now = Date()
        let updatedLease = existingLease.updated(
            state: existingLease.state,
            updatedAt: now > existingLease.updatedAt
                ? now
                : existingLease.updatedAt.addingTimeInterval(0.000_001),
            demand: demand
        )
        consumerLeasesByID[existingLease.id] = updatedLease
        return updatedLease
    }

    private func attachConsumer(
        surfaceIdentity: DisplaySurfaceIdentity,
        kind: DisplaySurfaceConsumerKind,
        owner: DisplayRuntimeConsumerOwner,
        demand: DisplayRuntimeConsumerDemand,
        submitsCaptureIntent: Bool
    ) -> DisplayRuntimeConsumerLease {
        if kind == .lanWebView,
           let existingLease = currentDemandLeases(for: surfaceIdentity)
           .first(where: { $0.kind == .lanWebView }) {
            let now = Date()
            let updatedLease = existingLease.updated(
                state: existingLease.state,
                updatedAt: now > existingLease.updatedAt
                    ? now
                    : existingLease.updatedAt.addingTimeInterval(0.000_001),
                demand: demand
            )
            consumerLeasesByID[existingLease.id] = updatedLease
            return updatedLease
        }

        let now = Date()
        let surfaceEpoch = currentSurfaceEpoch(for: surfaceIdentity)
        let resolvedDisplayID = resolvedDisplayID(for: surfaceIdentity, surfaces: nil)
        let lease = DisplayRuntimeConsumerLease(
            surfaceIdentity: surfaceIdentity,
            surfaceEpoch: surfaceEpoch,
            resolvedDisplayID: resolvedDisplayID,
            kind: kind,
            owner: owner,
            createdAt: now,
            updatedAt: now,
            state: .attached,
            demand: demand
        )
        consumerLeasesByID[lease.id] = lease
        if submitsCaptureIntent {
            submitCaptureIntent(surfaceIdentity: surfaceIdentity, reason: .attach)
        }
        return lease
    }

    @discardableResult
    package func detachConsumer(
        leaseID: DisplayRuntimeConsumerLeaseID
    ) -> DisplayRuntimeConsumerLease? {
        guard let releasedLease = releaseConsumerLease(leaseID: leaseID) else { return nil }
        submitCaptureIntent(surfaceIdentity: releasedLease.surfaceIdentity, reason: .detach)
        return releasedLease
    }

    @discardableResult
    package func detachPreviewConsumer(
        surfaceIdentity: DisplaySurfaceIdentity
    ) -> DisplayRuntimePreviewConsumerDetachResult {
        guard let lease = currentDemandLeases(for: surfaceIdentity)
            .first(where: { $0.kind == .preview })
        else {
            return DisplayRuntimePreviewConsumerDetachResult(
                releasedLease: nil,
                applyResult: nil
            )
        }

        let releasedLease = detachConsumer(leaseID: lease.id)
        let applyResult = currentEffectiveCaptureIntentSnapshot()
            .first { $0.intent.surfaceIdentity == surfaceIdentity }?
            .lastApplyResult
        return DisplayRuntimePreviewConsumerDetachResult(
            releasedLease: releasedLease,
            applyResult: applyResult
        )
    }

    @discardableResult
    package func detachLANWebViewConsumer(
        surfaceIdentity: DisplaySurfaceIdentity
    ) async -> DisplayRuntimeLANWebViewConsumerDetachResult {
        guard let lease = currentDemandLeases(for: surfaceIdentity)
            .first(where: { $0.kind == .lanWebView })
        else {
            return DisplayRuntimeLANWebViewConsumerDetachResult(
                releasedLease: nil,
                applyResult: nil
            )
        }
        guard let releasedLease = releaseConsumerLease(leaseID: lease.id) else {
            return DisplayRuntimeLANWebViewConsumerDetachResult(
                releasedLease: nil,
                applyResult: nil
            )
        }

        let intent = submitCaptureIntent(
            surfaceIdentity: releasedLease.surfaceIdentity,
            reason: .detach,
            appliesCommand: false
        )
        let rawResult: DisplayRuntimeCaptureIntentApplyResult
        if let captureIntentCommander {
            rawResult = await captureIntentCommander.applyLANWebViewCaptureIntent(intent)
        } else {
            rawResult = .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.adapterUnavailable
            )
        }
        return DisplayRuntimeLANWebViewConsumerDetachResult(
            releasedLease: releasedLease,
            applyResult: recordCaptureIntentApplyResult(rawResult)
        )
    }

    @discardableResult
    package func detachDiagnosticsRecorderConsumer(
        leaseID: DisplayRuntimeConsumerLeaseID
    ) async -> DisplayRuntimeDiagnosticsRecorderDetachResult {
        guard consumerLeasesByID[leaseID]?.kind == .diagnosticsRecorder,
              let releasedLease = releaseConsumerLease(leaseID: leaseID)
        else {
            return DisplayRuntimeDiagnosticsRecorderDetachResult(
                releasedLease: nil,
                applyResult: nil
            )
        }

        let intent = submitCaptureIntent(
            surfaceIdentity: releasedLease.surfaceIdentity,
            reason: .detach,
            appliesCommand: false
        )
        let rawResult: DisplayRuntimeCaptureIntentApplyResult
        if let captureIntentCommander {
            rawResult = await captureIntentCommander.applyDiagnosticsRecorderCaptureIntent(intent)
        } else {
            rawResult = .failed(
                revision: intent.revision,
                failureCode: DisplayRuntimeCaptureIntentFailureCode.adapterUnavailable
            )
        }
        return DisplayRuntimeDiagnosticsRecorderDetachResult(
            releasedLease: releasedLease,
            applyResult: recordCaptureIntentApplyResult(rawResult)
        )
    }

    private func releaseConsumerLease(
        leaseID: DisplayRuntimeConsumerLeaseID
    ) -> DisplayRuntimeConsumerLease? {
        guard let lease = consumerLeasesByID[leaseID] else { return nil }
        let releasedLease = lease.updated(
            state: .released,
            updatedAt: Date()
        )
        consumerLeasesByID[leaseID] = releasedLease
        return releasedLease
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
        let now = Date()
        let nextEpoch = currentSurfaceEpoch(for: surfaceIdentity).advanced()
        surfaceEpochs[surfaceIdentity] = nextEpoch
        if let resolvedDisplayID {
            surfaceResolvedDisplayIDs[surfaceIdentity] = resolvedDisplayID
        } else {
            surfaceResolvedDisplayIDs.removeValue(forKey: surfaceIdentity)
        }

        for lease in currentDemandLeases(for: surfaceIdentity) where lease.surfaceEpoch != nextEpoch {
            consumerLeasesByID[lease.id] = lease.updated(
                state: .restarting,
                surfaceEpoch: lease.surfaceEpoch,
                resolvedDisplayID: lease.resolvedDisplayID,
                updatedAt: now,
                lastFailureCode: DisplayRuntimeCaptureIntentFailureCode.epochMismatch
            )
        }
        submitCaptureIntent(surfaceIdentity: surfaceIdentity, reason: .epochChanged)
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

    private func aggregateDemand(
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
    private func submitCaptureIntent(
        surfaceIdentity: DisplaySurfaceIdentity,
        reason: DisplayRuntimeCaptureIntentReason,
        appliesCommand: Bool = true
    ) -> DisplayRuntimeCaptureIntent {
        let aggregateDemand = aggregateDemand(for: surfaceIdentity, surfaces: nil)
        let intent = DisplayRuntimeCaptureIntent(
            surfaceIdentity: surfaceIdentity,
            surfaceEpoch: currentSurfaceEpoch(for: surfaceIdentity),
            resolvedDisplayID: resolvedDisplayID(for: surfaceIdentity, surfaces: nil),
            aggregateDemand: aggregateDemand,
            kind: aggregateDemand == nil ? .drain : .capture,
            reason: reason,
            revision: nextCaptureIntentRevision()
        )
        captureIntentsByRevision[intent.revision] = intent
        effectiveCaptureIntentsBySurface[surfaceIdentity] = DisplayRuntimeEffectiveCaptureIntent(intent: intent)
        if appliesCommand, let applyResult = captureIntentCommander?.applyCaptureIntent(intent) {
            _ = recordCaptureIntentApplyResult(applyResult)
        }
        return intent
    }

    private func nextCaptureIntentRevision() -> DisplayRuntimeCaptureIntentRevision {
        captureIntentRevisionCounter += 1
        return DisplayRuntimeCaptureIntentRevision(rawValue: captureIntentRevisionCounter)
    }

    private func currentDemandLeases(
        for surfaceIdentity: DisplaySurfaceIdentity
    ) -> [DisplayRuntimeConsumerLease] {
        consumerLeasesByID.values
            .filter { $0.surfaceIdentity == surfaceIdentity }
            .filter { $0.state.contributesDemand }
            .sorted(by: leaseSort)
    }

    private func resolvedDisplayID(
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

private extension DisplayRuntimeConsumerLease {
    func updated(
        state: DisplayRuntimeConsumerLeaseState,
        surfaceEpoch: DisplaySurfaceEpoch? = nil,
        resolvedDisplayID: DisplayRuntimeDisplayID? = nil,
        updatedAt: Date,
        demand: DisplayRuntimeConsumerDemand? = nil,
        lastFailureCode: String? = nil
    ) -> DisplayRuntimeConsumerLease {
        DisplayRuntimeConsumerLease(
            id: id,
            surfaceIdentity: surfaceIdentity,
            surfaceEpoch: surfaceEpoch ?? self.surfaceEpoch,
            resolvedDisplayID: resolvedDisplayID ?? self.resolvedDisplayID,
            kind: kind,
            owner: owner,
            createdAt: createdAt,
            updatedAt: updatedAt,
            state: state,
            demand: demand ?? self.demand,
            lastFailureCode: lastFailureCode
        )
    }
}
