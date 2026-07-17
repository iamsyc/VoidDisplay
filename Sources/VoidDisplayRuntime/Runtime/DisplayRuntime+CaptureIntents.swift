import Foundation

@MainActor
extension DisplayRuntime {
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

    func shouldCompensateCaptureIntent(
        _ intent: DisplayRuntimeCaptureIntent,
        after result: DisplayRuntimeCaptureIntentApplyResult
    ) -> Bool {
        guard result.outcome != .applied else { return false }
        return effectiveCaptureIntentsBySurface[intent.surfaceIdentity]?.intent.revision
            == intent.revision
    }

    func failLeaseIfCurrentCompensationDidNotApply(
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
}
