import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
package nonisolated enum DisplayCaptureFrameRateTier: Int, CaseIterable, Sendable, Equatable {
    case fps30 = 30
    case fps45 = 45
    case fps60 = 60

    package var framesPerSecond: Int {
        rawValue
    }

    package var nextLowerTier: DisplayCaptureFrameRateTier? {
        switch self {
        case .fps60:
            .fps45
        case .fps45:
            .fps30
        case .fps30:
            nil
        }
    }

    package var nextHigherTier: DisplayCaptureFrameRateTier? {
        switch self {
        case .fps30:
            .fps45
        case .fps45:
            .fps60
        case .fps60:
            nil
        }
    }
}
package nonisolated enum DisplayCaptureProfile: String, Sendable, Equatable {
    case previewOnly
    case shareOnly
    case mixed
}
package nonisolated enum DisplayCaptureProfileDecision: Sendable, Equatable {
    case noChange
    case applyNow(DisplayCaptureProfile)
    case applyAfter(DisplayCaptureProfile, delayNanoseconds: UInt64)
}
package nonisolated struct DisplayCaptureDemandSnapshot: Sendable, Equatable {
    package var attachedPreviewSinkCount: Int
    package var shareTokenCount: Int
    package var previewShowsCursor: Bool
    package var shareCursorOverrideCount: Int
    package var performanceMode: CapturePerformanceMode

    package init(
        attachedPreviewSinkCount: Int = 0,
        shareTokenCount: Int = 0,
        previewShowsCursor: Bool = false,
        shareCursorOverrideCount: Int = 0,
        performanceMode: CapturePerformanceMode
    ) {
        self.attachedPreviewSinkCount = max(0, attachedPreviewSinkCount)
        self.shareTokenCount = max(0, shareTokenCount)
        self.previewShowsCursor = previewShowsCursor
        self.shareCursorOverrideCount = max(0, shareCursorOverrideCount)
        self.performanceMode = performanceMode
    }

    nonisolated var desiredProfile: DisplayCaptureProfile? {
        DisplayCaptureProfileStateMachine.desiredProfile(for: self)
    }

    nonisolated var showsCursor: Bool {
        previewShowsCursor || shareCursorOverrideCount > 0
    }

    nonisolated var isEmpty: Bool {
        attachedPreviewSinkCount == 0 && shareTokenCount == 0 && !showsCursor
    }
}
package nonisolated enum DisplayCaptureProfileStateMachine {
    nonisolated static func desiredProfile(for demand: DisplayCaptureDemandSnapshot) -> DisplayCaptureProfile? {
        switch (demand.attachedPreviewSinkCount > 0, demand.shareTokenCount > 0) {
        case (true, false):
            .previewOnly
        case (false, true):
            .shareOnly
        case (true, true):
            .mixed
        case (false, false):
            nil
        }
    }

    nonisolated static func decideTransition(
        demand: DisplayCaptureDemandSnapshot,
        currentProfile: DisplayCaptureProfile,
        lastProfileSwitchTimeNs: UInt64?,
        nowNs: UInt64,
        minimumDwellNanoseconds: UInt64
    ) -> DisplayCaptureProfileDecision {
        guard let desiredProfile = desiredProfile(for: demand) else {
            return .noChange
        }
        guard desiredProfile != currentProfile else {
            return .noChange
        }
        guard let lastProfileSwitchTimeNs else {
            return .applyNow(desiredProfile)
        }

        let elapsed = nowNs &- lastProfileSwitchTimeNs
        if elapsed >= minimumDwellNanoseconds {
            return .applyNow(desiredProfile)
        }
        return .applyAfter(
            desiredProfile,
            delayNanoseconds: minimumDwellNanoseconds - elapsed
        )
    }
}
package nonisolated struct DisplayCaptureProfileCoordinatorState: Sendable {
    package var demand: DisplayCaptureDemandSnapshot
    package var committedProfile: DisplayCaptureProfile
    package var inFlightProfile: DisplayCaptureProfile?
    package var lastProfileSwitchTimeNs: UInt64?

    nonisolated init(
        committedProfile: DisplayCaptureProfile,
        demand: DisplayCaptureDemandSnapshot,
        lastProfileSwitchTimeNs: UInt64? = nil
    ) {
        self.demand = demand
        self.committedProfile = committedProfile
        self.lastProfileSwitchTimeNs = lastProfileSwitchTimeNs
    }

    nonisolated mutating func updateDemand(
        _ demand: DisplayCaptureDemandSnapshot,
        nowNs: UInt64,
        minimumDwellNanoseconds: UInt64
    ) -> DisplayCaptureProfileDecision {
        self.demand = demand
        return evaluateTransition(
            nowNs: nowNs,
            minimumDwellNanoseconds: minimumDwellNanoseconds
        )
    }

    nonisolated mutating func resumeScheduledTransition(
        nowNs: UInt64,
        minimumDwellNanoseconds: UInt64
    ) -> DisplayCaptureProfileDecision {
        evaluateTransition(
            nowNs: nowNs,
            minimumDwellNanoseconds: minimumDwellNanoseconds
        )
    }

    nonisolated mutating func finishAppliedTransition(
        at nowNs: UInt64,
        minimumDwellNanoseconds: UInt64
    ) -> DisplayCaptureProfileDecision {
        guard let inFlightProfile else { return .noChange }
        committedProfile = inFlightProfile
        self.inFlightProfile = nil
        lastProfileSwitchTimeNs = nowNs
        return evaluateTransition(
            nowNs: nowNs,
            minimumDwellNanoseconds: minimumDwellNanoseconds
        )
    }

    nonisolated mutating func failAppliedTransition() {
        inFlightProfile = nil
    }

    nonisolated private mutating func evaluateTransition(
        nowNs: UInt64,
        minimumDwellNanoseconds: UInt64
    ) -> DisplayCaptureProfileDecision {
        guard inFlightProfile == nil else {
            return .noChange
        }

        let decision = DisplayCaptureProfileStateMachine.decideTransition(
            demand: demand,
            currentProfile: committedProfile,
            lastProfileSwitchTimeNs: lastProfileSwitchTimeNs,
            nowNs: nowNs,
            minimumDwellNanoseconds: minimumDwellNanoseconds
        )
        if case .applyNow(let profile) = decision {
            inFlightProfile = profile
        }
        return decision
    }
}
package nonisolated struct DisplayCaptureTaskLifetimeState: Sendable {
    private(set) var currentGeneration: UInt64 = 0

    nonisolated mutating func invalidateAllTasks() -> UInt64 {
        currentGeneration &+= 1
        return currentGeneration
    }

    nonisolated func allowsExecution(for generation: UInt64) -> Bool {
        currentGeneration == generation
    }
}
package nonisolated struct DisplayPreviewPerformanceSample: Sendable, Equatable {
    package let renderedFrameCount: UInt64
    package let droppedFrameCount: UInt64
    package let latestRenderLatencyMilliseconds: Double
    package let pendingSlotOccupied: Bool
    package let capturedAt: UInt64

    package init(
        renderedFrameCount: UInt64,
        droppedFrameCount: UInt64,
        latestRenderLatencyMilliseconds: Double,
        pendingSlotOccupied: Bool,
        capturedAt: UInt64
    ) {
        self.renderedFrameCount = renderedFrameCount
        self.droppedFrameCount = droppedFrameCount
        self.latestRenderLatencyMilliseconds = latestRenderLatencyMilliseconds
        self.pendingSlotOccupied = pendingSlotOccupied
        self.capturedAt = capturedAt
    }

    nonisolated var totalFrameCount: UInt64 {
        renderedFrameCount &+ droppedFrameCount
    }

    nonisolated var droppedFrameRatio: Double {
        let total = max(1, totalFrameCount)
        return Double(droppedFrameCount) / Double(total)
    }
}
package nonisolated struct DisplayCaptureConfiguration: Sendable, Equatable {
    package let profile: DisplayCaptureProfile
    package let frameRateTier: DisplayCaptureFrameRateTier
}
package nonisolated enum DisplayCaptureConfigurationDecision: Sendable, Equatable {
    case noChange
    case applyNow(DisplayCaptureConfiguration)
    case applyAfter(DisplayCaptureConfiguration, delayNanoseconds: UInt64)
}
package nonisolated struct DisplayCaptureAdaptivePolicyState: Sendable, Equatable {
    private(set) var currentAutomaticMixedTier: DisplayCaptureFrameRateTier = .fps45
    private(set) var stableWindowCount = 0
    private(set) var pressureWindowCount = 0

    mutating func resetToDefaultAutomaticMixedTier() {
        currentAutomaticMixedTier = .fps45
        stableWindowCount = 0
        pressureWindowCount = 0
    }

    mutating func rebase(
        desiredProfile: DisplayCaptureProfile?,
        performanceMode: CapturePerformanceMode
    ) {
        guard desiredProfile == .mixed, performanceMode == .automatic else {
            resetToDefaultAutomaticMixedTier()
            return
        }
    }

    mutating func recordAutomaticMixedSample(
        _ sample: DisplayPreviewPerformanceSample
    ) -> DisplayCaptureFrameRateTier? {
        guard sample.totalFrameCount > 0 else {
            stableWindowCount = 0
            pressureWindowCount = 0
            return nil
        }
        let isPressureWindow = sample.droppedFrameRatio >= 0.08
            || sample.latestRenderLatencyMilliseconds >= 35
            || sample.pendingSlotOccupied
        let isStableWindow = sample.droppedFrameRatio < 0.02
            && sample.latestRenderLatencyMilliseconds < 20
            && !sample.pendingSlotOccupied

        if isPressureWindow {
            pressureWindowCount += 1
            stableWindowCount = 0
            if pressureWindowCount >= 2, let nextLowerTier = currentAutomaticMixedTier.nextLowerTier {
                currentAutomaticMixedTier = nextLowerTier
                stableWindowCount = 0
                pressureWindowCount = 0
                return nextLowerTier
            }
            return nil
        }

        if isStableWindow {
            stableWindowCount += 1
            pressureWindowCount = 0
            if stableWindowCount >= 4, let nextHigherTier = currentAutomaticMixedTier.nextHigherTier {
                currentAutomaticMixedTier = nextHigherTier
                stableWindowCount = 0
                pressureWindowCount = 0
                return nextHigherTier
            }
            return nil
        }

        stableWindowCount = 0
        pressureWindowCount = 0
        return nil
    }
}
package nonisolated enum DisplayCaptureConfigurationStateMachine {
    nonisolated static func defaultFrameRateTier(
        for profile: DisplayCaptureProfile,
        performanceMode: CapturePerformanceMode,
        adaptivePolicy: DisplayCaptureAdaptivePolicyState = .init()
    ) -> DisplayCaptureFrameRateTier {
        switch performanceMode {
        case .automatic:
            switch profile {
            case .previewOnly:
                .fps60
            case .shareOnly:
                .fps60
            case .mixed:
                adaptivePolicy.currentAutomaticMixedTier
            }
        case .smooth:
            .fps60
        case .powerEfficient:
            switch profile {
            case .previewOnly:
                .fps45
            case .shareOnly, .mixed:
                .fps30
            }
        }
    }

    nonisolated static func desiredConfiguration(
        for demand: DisplayCaptureDemandSnapshot,
        adaptivePolicy: DisplayCaptureAdaptivePolicyState
    ) -> DisplayCaptureConfiguration? {
        guard let profile = demand.desiredProfile else {
            return nil
        }
        return DisplayCaptureConfiguration(
            profile: profile,
            frameRateTier: defaultFrameRateTier(
                for: profile,
                performanceMode: demand.performanceMode,
                adaptivePolicy: adaptivePolicy
            )
        )
    }

    nonisolated static func decideTransition(
        desiredConfiguration: DisplayCaptureConfiguration?,
        currentConfiguration: DisplayCaptureConfiguration,
        lastConfigurationSwitchTimeNs: UInt64?,
        nowNs: UInt64,
        minimumDwellNanoseconds: UInt64
    ) -> DisplayCaptureConfigurationDecision {
        guard let desiredConfiguration else { return .noChange }
        guard desiredConfiguration != currentConfiguration else { return .noChange }
        guard let lastConfigurationSwitchTimeNs else {
            return .applyNow(desiredConfiguration)
        }

        let elapsed = nowNs &- lastConfigurationSwitchTimeNs
        if elapsed >= minimumDwellNanoseconds {
            return .applyNow(desiredConfiguration)
        }
        return .applyAfter(
            desiredConfiguration,
            delayNanoseconds: minimumDwellNanoseconds - elapsed
        )
    }
}
package nonisolated struct DisplayCaptureConfigurationCoordinatorState: Sendable, Equatable {
    package var demand: DisplayCaptureDemandSnapshot
    package var adaptivePolicy = DisplayCaptureAdaptivePolicyState()
    package var committedConfiguration: DisplayCaptureConfiguration
    package var inFlightConfiguration: DisplayCaptureConfiguration?
    package var lastConfigurationSwitchTimeNs: UInt64?

    package init(
        committedConfiguration: DisplayCaptureConfiguration,
        demand: DisplayCaptureDemandSnapshot,
        lastConfigurationSwitchTimeNs: UInt64? = nil
    ) {
        self.demand = demand
        self.committedConfiguration = committedConfiguration
        self.lastConfigurationSwitchTimeNs = lastConfigurationSwitchTimeNs
        adaptivePolicy.rebase(
            desiredProfile: committedConfiguration.profile,
            performanceMode: demand.performanceMode
        )
    }

    mutating func updateDemand(
        _ demand: DisplayCaptureDemandSnapshot,
        nowNs: UInt64,
        minimumDwellNanoseconds: UInt64
    ) -> DisplayCaptureConfigurationDecision {
        self.demand = demand
        adaptivePolicy.rebase(
            desiredProfile: currentDesiredProfile,
            performanceMode: demand.performanceMode
        )
        return evaluateTransition(
            nowNs: nowNs,
            minimumDwellNanoseconds: minimumDwellNanoseconds
        )
    }

    mutating func recordPreviewPerformanceSample(
        _ sample: DisplayPreviewPerformanceSample,
        nowNs: UInt64,
        minimumDwellNanoseconds: UInt64
    ) -> DisplayCaptureConfigurationDecision {
        let desiredProfile = currentDesiredProfile
        adaptivePolicy.rebase(desiredProfile: desiredProfile, performanceMode: demand.performanceMode)
        guard desiredProfile == .mixed, demand.performanceMode == .automatic else {
            return evaluateTransition(
                nowNs: nowNs,
                minimumDwellNanoseconds: minimumDwellNanoseconds
            )
        }
        _ = adaptivePolicy.recordAutomaticMixedSample(sample)
        return evaluateTransition(
            nowNs: nowNs,
            minimumDwellNanoseconds: minimumDwellNanoseconds
        )
    }

    mutating func resumeScheduledTransition(
        nowNs: UInt64,
        minimumDwellNanoseconds: UInt64
    ) -> DisplayCaptureConfigurationDecision {
        evaluateTransition(
            nowNs: nowNs,
            minimumDwellNanoseconds: minimumDwellNanoseconds
        )
    }

    mutating func finishAppliedTransition(
        at nowNs: UInt64,
        minimumDwellNanoseconds: UInt64
    ) -> DisplayCaptureConfigurationDecision {
        guard let inFlightConfiguration else { return .noChange }
        committedConfiguration = inFlightConfiguration
        self.inFlightConfiguration = nil
        lastConfigurationSwitchTimeNs = nowNs
        adaptivePolicy.rebase(
            desiredProfile: committedConfiguration.profile,
            performanceMode: demand.performanceMode
        )
        return evaluateTransition(
            nowNs: nowNs,
            minimumDwellNanoseconds: minimumDwellNanoseconds
        )
    }

    mutating func failAppliedTransition() {
        inFlightConfiguration = nil
    }

    private var currentDesiredProfile: DisplayCaptureProfile? {
        demand.desiredProfile
    }

    private mutating func evaluateTransition(
        nowNs: UInt64,
        minimumDwellNanoseconds: UInt64
    ) -> DisplayCaptureConfigurationDecision {
        guard inFlightConfiguration == nil else {
            return .noChange
        }
        let decision = DisplayCaptureConfigurationStateMachine.decideTransition(
            desiredConfiguration: DisplayCaptureConfigurationStateMachine.desiredConfiguration(
                for: demand,
                adaptivePolicy: adaptivePolicy
            ),
            currentConfiguration: committedConfiguration,
            lastConfigurationSwitchTimeNs: lastConfigurationSwitchTimeNs,
            nowNs: nowNs,
            minimumDwellNanoseconds: minimumDwellNanoseconds
        )
        if case .applyNow(let configuration) = decision {
            inFlightConfiguration = configuration
        }
        return decision
    }
}
package protocol DisplayPreviewSink: AnyObject, Sendable {
    nonisolated func submitFrame(_ sampleBuffer: CMSampleBuffer)
}
package struct DisplayCaptureMetricsSnapshot: Sendable {
    package var currentProfile: DisplayCaptureProfile?
    package var currentFrameRateTier: DisplayCaptureFrameRateTier?
    package var receivedFrameCount: UInt64
    package var profileReconfigurationCount: UInt64
    package var cursorOverrideReconfigurationCount: UInt64
}
package protocol DisplayCaptureSessioning: AnyObject, Sendable {
    nonisolated var shareFrameConsumer: any DisplayShareFrameConsumer { get }
    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink)
    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink)
    nonisolated func reportPreviewPerformanceSample(_ sample: DisplayPreviewPerformanceSample)
    nonisolated func stopSharing()
    nonisolated func setDemand(_ demand: DisplayCaptureDemandSnapshot) async throws
    nonisolated func captureMetricsSnapshot() -> DisplayCaptureMetricsSnapshot
    nonisolated func stop() async
}

package extension DisplayCaptureSessioning {
    nonisolated func reportPreviewPerformanceSample(_ sample: DisplayPreviewPerformanceSample) {
        _ = sample
    }

    nonisolated func setDemand(_ demand: DisplayCaptureDemandSnapshot) async throws {
        _ = demand
    }

    nonisolated func captureMetricsSnapshot() -> DisplayCaptureMetricsSnapshot {
        .init(
            currentProfile: nil,
            currentFrameRateTier: nil,
            receivedFrameCount: 0,
            profileReconfigurationCount: 0,
            cursorOverrideReconfigurationCount: 0
        )
    }
}
