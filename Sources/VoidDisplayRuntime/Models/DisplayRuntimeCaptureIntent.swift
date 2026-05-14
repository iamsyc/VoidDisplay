import Foundation

package nonisolated struct DisplayRuntimeCaptureIntentRevision: Codable, Comparable, Equatable, Hashable, Sendable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

package nonisolated enum DisplayRuntimeCaptureIntentKind: String, Codable, Equatable, Sendable {
    case capture
    case drain
}

package nonisolated enum DisplayRuntimeCaptureIntentReason: String, Codable, Equatable, Sendable {
    case attach
    case detach
    case epochChanged
    case transactionQuiesce
    case performanceModeChanged
}

package nonisolated struct DisplayRuntimeCaptureIntent: Codable, Equatable, Sendable {
    package let surfaceIdentity: DisplaySurfaceIdentity
    package let surfaceEpoch: DisplaySurfaceEpoch
    package let resolvedDisplayID: DisplayRuntimeDisplayID?
    package let aggregateDemand: DisplayRuntimeAggregatedDemand?
    package let kind: DisplayRuntimeCaptureIntentKind
    package let reason: DisplayRuntimeCaptureIntentReason
    package let revision: DisplayRuntimeCaptureIntentRevision
    package let lastFailureCode: String?

    package init(
        surfaceIdentity: DisplaySurfaceIdentity,
        surfaceEpoch: DisplaySurfaceEpoch,
        resolvedDisplayID: DisplayRuntimeDisplayID?,
        aggregateDemand: DisplayRuntimeAggregatedDemand?,
        kind: DisplayRuntimeCaptureIntentKind,
        reason: DisplayRuntimeCaptureIntentReason,
        revision: DisplayRuntimeCaptureIntentRevision,
        lastFailureCode: String? = nil
    ) {
        self.surfaceIdentity = surfaceIdentity
        self.surfaceEpoch = surfaceEpoch
        self.resolvedDisplayID = resolvedDisplayID
        self.aggregateDemand = aggregateDemand
        self.kind = kind
        self.reason = reason
        self.revision = revision
        self.lastFailureCode = lastFailureCode
    }
}

package nonisolated enum DisplayRuntimeCaptureIntentApplyOutcome: String, Codable, Equatable, Sendable {
    case applied
    case failed
    case ignored
}

package nonisolated struct DisplayRuntimeCaptureIntentApplyResult: Codable, Equatable, Sendable {
    package let revision: DisplayRuntimeCaptureIntentRevision
    package let outcome: DisplayRuntimeCaptureIntentApplyOutcome
    package let failureCode: String?

    package init(
        revision: DisplayRuntimeCaptureIntentRevision,
        outcome: DisplayRuntimeCaptureIntentApplyOutcome,
        failureCode: String? = nil
    ) {
        self.revision = revision
        self.outcome = outcome
        self.failureCode = failureCode
    }

    package func ignored() -> Self {
        Self(revision: revision, outcome: .ignored)
    }
}

package nonisolated struct DisplayRuntimeEffectiveCaptureIntent: Codable, Equatable, Sendable {
    package let intent: DisplayRuntimeCaptureIntent
    package let lastApplyResult: DisplayRuntimeCaptureIntentApplyResult?
    package let lastFailureCode: String?

    package init(
        intent: DisplayRuntimeCaptureIntent,
        lastApplyResult: DisplayRuntimeCaptureIntentApplyResult? = nil,
        lastFailureCode: String? = nil
    ) {
        self.intent = intent
        self.lastApplyResult = lastApplyResult
        self.lastFailureCode = lastFailureCode
    }
}
