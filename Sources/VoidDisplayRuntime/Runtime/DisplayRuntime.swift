import Foundation
import Observation

package nonisolated struct DisplayRuntimeTopologyWaitPolicy: Equatable, Sendable {
    package let requiredStableSampleCount: Int
    package let maximumSampleCount: Int
    package let sampleIntervalNanoseconds: UInt64

    package init(
        requiredStableSampleCount: Int = 2,
        maximumSampleCount: Int = 10,
        sampleIntervalNanoseconds: UInt64 = 100_000_000
    ) {
        self.requiredStableSampleCount = max(1, requiredStableSampleCount)
        self.maximumSampleCount = max(1, maximumSampleCount)
        self.sampleIntervalNanoseconds = sampleIntervalNanoseconds
    }

    package static let `default` = Self()
}

nonisolated struct DisplayRuntimeCaptureIntentApplyKey: Hashable, Sendable {
    let surfaceIdentity: DisplaySurfaceIdentity
    let consumerKind: DisplaySurfaceConsumerKind
}

nonisolated struct DisplayRuntimeCaptureIntentApplyTail: Sendable {
    let id: UUID
    let task: Task<DisplayRuntimeCaptureIntentApplyResult, Never>
}

@MainActor
@Observable
package final class DisplayRuntime {
    let catalogProvider: (any DisplayRuntimeCatalogProviding)?
    let captureProvider: (any DisplayRuntimeCaptureProviding)?
    let sharingProvider: (any DisplayRuntimeSharingProviding)?
    let virtualDisplayProvider: (any DisplayRuntimeVirtualDisplayProviding)?
    let catalogCommander: (any DisplayRuntimeCatalogCommanding)?
    let sharingCommander: (any DisplayRuntimeSharingCommanding)?
    let captureIntentCommander: (any DisplayRuntimeCaptureIntentCommanding)?
    let virtualDisplayCommander: (any DisplayRuntimeVirtualDisplayCommanding)?
    let startupRestoreCommander: (any DisplayRuntimeStartupRestoreCommanding)?
    let observabilityRecorder: (any DisplayRuntimeObservabilityRecording)?
    let topologyWaitPolicy: DisplayRuntimeTopologyWaitPolicy

    var consumerLeasesByID: [DisplayRuntimeConsumerLeaseID: DisplayRuntimeConsumerLease] = [:]
    var surfaceEpochs: [DisplaySurfaceIdentity: DisplaySurfaceEpoch] = [:]
    var surfaceResolvedDisplayIDs: [DisplaySurfaceIdentity: DisplayRuntimeDisplayID] = [:]
    var captureIntentRevisionCounter: UInt64 = 0
    var captureIntentsByRevision: [DisplayRuntimeCaptureIntentRevision: DisplayRuntimeCaptureIntent] = [:]
    var effectiveCaptureIntentsBySurface: [DisplaySurfaceIdentity: DisplayRuntimeEffectiveCaptureIntent] = [:]
    var captureIntentApplyResultsByRevision: [
        DisplayRuntimeCaptureIntentRevision: DisplayRuntimeCaptureIntentApplyResult
    ] = [:]
    var consumerTransitionBusySurfaces: Set<DisplaySurfaceIdentity> = []
    @ObservationIgnored var previewLeaseWaiters: [
        DisplayRuntimeConsumerLeaseID: [UUID: CheckedContinuation<DisplayRuntimeConsumerLease?, Never>]
    ] = [:]
    @ObservationIgnored var captureIntentApplyTails: [
        DisplayRuntimeCaptureIntentApplyKey: DisplayRuntimeCaptureIntentApplyTail
    ] = [:]

    @ObservationIgnored var topologyRefreshTask: Task<Void, Never>?
    @ObservationIgnored var hasPendingTopologyChange = false
    @ObservationIgnored var activeCatalogSurfaceRegistrations: [
        DisplayRuntimeCatalogSource: Set<DisplayRuntimeCatalogSurfaceRegistration>
    ] = [:]
    @ObservationIgnored var virtualDisplayTransactionQueueTail: Task<Void, Never>?
    @ObservationIgnored var coalescibleVirtualDisplayTransactionTail: ActiveVirtualDisplayCoalescibleTail?
    var activeTransactionTracesByID: [DisplayRuntimeTransactionID: DisplayRuntimeTransactionTrace] = [:]
    var recentTransactionTraces: [DisplayRuntimeTransactionTrace] = []
    @ObservationIgnored var activeStartupRestoreTask: Task<DisplayRuntimeStartupRestoreResult, Never>?
    @ObservationIgnored var activeStartupRestoreCoalescedRequestCount = 0
    var completedStartupRestoreResult: DisplayRuntimeStartupRestoreResult?

    package init(
        catalogProvider: (any DisplayRuntimeCatalogProviding)? = nil,
        captureProvider: (any DisplayRuntimeCaptureProviding)? = nil,
        sharingProvider: (any DisplayRuntimeSharingProviding)? = nil,
        virtualDisplayProvider: (any DisplayRuntimeVirtualDisplayProviding)? = nil,
        catalogCommander: (any DisplayRuntimeCatalogCommanding)? = nil,
        sharingCommander: (any DisplayRuntimeSharingCommanding)? = nil,
        captureIntentCommander: (any DisplayRuntimeCaptureIntentCommanding)? = nil,
        virtualDisplayCommander: (any DisplayRuntimeVirtualDisplayCommanding)? = nil,
        startupRestoreCommander: (any DisplayRuntimeStartupRestoreCommanding)? = nil,
        observabilityRecorder: (any DisplayRuntimeObservabilityRecording)? = nil,
        topologyWaitPolicy: DisplayRuntimeTopologyWaitPolicy = .default
    ) {
        self.catalogProvider = catalogProvider
        self.captureProvider = captureProvider
        self.sharingProvider = sharingProvider
        self.virtualDisplayProvider = virtualDisplayProvider
        self.catalogCommander = catalogCommander
        self.sharingCommander = sharingCommander
        self.captureIntentCommander = captureIntentCommander
        self.virtualDisplayCommander = virtualDisplayCommander
        self.startupRestoreCommander = startupRestoreCommander
        self.observabilityRecorder = observabilityRecorder
        self.topologyWaitPolicy = topologyWaitPolicy
    }

}
