@MainActor
extension DisplayRuntime {
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
}
