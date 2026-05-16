import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
package nonisolated struct DisplayCaptureFrameRateTier: Sendable, Equatable, Hashable {
    package static let fps30 = DisplayCaptureFrameRateTier(framesPerSecond: 30)
    package static let fps45 = DisplayCaptureFrameRateTier(framesPerSecond: 45)
    package static let fps60 = DisplayCaptureFrameRateTier(framesPerSecond: 60)

    package let framesPerSecond: Int

    package init(framesPerSecond: Int) {
        self.framesPerSecond = max(1, framesPerSecond)
    }
}

package typealias DisplayCaptureDimensions = CapturePixelDimensions

package nonisolated struct DisplayCaptureSizeContext: Sendable, Equatable {
    package static let defaultShared = DisplayCaptureSizeContext(
        logicalSize: .defaultShared,
        physicalSize: .defaultShared,
        sourceVideoSpec: .defaultShared
    )

    package let logicalSize: DisplayCaptureDimensions
    package let physicalSize: DisplayCaptureDimensions
    package let sourceVideoSpec: SourceVideoSpec

    package init(
        logicalSize: DisplayCaptureDimensions,
        physicalSize: DisplayCaptureDimensions,
        sourceFramesPerSecond: Int = 60
    ) {
        self.init(
            logicalSize: logicalSize,
            physicalSize: physicalSize,
            sourceVideoSpec: SourceVideoSpec(
                dimensions: physicalSize,
                framesPerSecond: sourceFramesPerSecond
            )
        )
    }

    package init(
        logicalSize: DisplayCaptureDimensions,
        physicalSize: DisplayCaptureDimensions,
        sourceVideoSpec: SourceVideoSpec
    ) {
        self.logicalSize = logicalSize
        self.physicalSize = physicalSize
        self.sourceVideoSpec = sourceVideoSpec
    }

    package func captureSize(
        for profile: DisplayCaptureProfile,
        performanceMode: CapturePerformanceMode
    ) -> DisplayCaptureDimensions {
        guard profile != .previewOnly else {
            return physicalSize
        }

        return SharedCapturePerformanceBudget(performanceMode: performanceMode)
            .captureDimensions(for: physicalSize)
    }
}
package nonisolated enum DisplayCaptureProfile: String, Sendable, Equatable {
    case previewOnly
    case shareOnly
    case mixed
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
package nonisolated struct DisplayCaptureConfiguration: Sendable, Equatable {
    package let profile: DisplayCaptureProfile
    package let frameRateTier: DisplayCaptureFrameRateTier

    package let captureSize: DisplayCaptureDimensions

    package init(
        profile: DisplayCaptureProfile,
        frameRateTier: DisplayCaptureFrameRateTier,
        captureSize: DisplayCaptureDimensions = .defaultShared
    ) {
        self.profile = profile
        self.frameRateTier = frameRateTier
        self.captureSize = captureSize
    }
}
package nonisolated enum DisplayCaptureConfigurationDecision: Sendable, Equatable {
    case noChange
    case applyNow(DisplayCaptureConfiguration)
    case applyAfter(DisplayCaptureConfiguration, delayNanoseconds: UInt64)
}
package nonisolated enum DisplayCaptureConfigurationStateMachine {
    nonisolated static func defaultFrameRateTier(
        for profile: DisplayCaptureProfile,
        performanceMode: CapturePerformanceMode,
        sourceFramesPerSecond: Int = 60
    ) -> DisplayCaptureFrameRateTier {
        let sourceFramesPerSecond = max(1, sourceFramesPerSecond)
        return switch performanceMode {
        case .automatic:
            DisplayCaptureFrameRateTier(framesPerSecond: sourceFramesPerSecond)
        case .smooth:
            DisplayCaptureFrameRateTier(framesPerSecond: sourceFramesPerSecond)
        case .powerEfficient:
            switch profile {
            case .previewOnly:
                DisplayCaptureFrameRateTier(framesPerSecond: min(sourceFramesPerSecond, 45))
            case .shareOnly, .mixed:
                DisplayCaptureFrameRateTier(framesPerSecond: min(sourceFramesPerSecond, 30))
            }
        }
    }

    nonisolated static func desiredConfiguration(
        for demand: DisplayCaptureDemandSnapshot,
        captureSizeContext: DisplayCaptureSizeContext
    ) -> DisplayCaptureConfiguration? {
        guard let profile = demand.desiredProfile else {
            return nil
        }
        return DisplayCaptureConfiguration(
            profile: profile,
            frameRateTier: defaultFrameRateTier(
                for: profile,
                performanceMode: demand.performanceMode,
                sourceFramesPerSecond: captureSizeContext.sourceVideoSpec.framesPerSecond
            ),
            captureSize: captureSizeContext.captureSize(
                for: profile,
                performanceMode: demand.performanceMode
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
    package var captureSizeContext: DisplayCaptureSizeContext
    package var committedConfiguration: DisplayCaptureConfiguration
    package var inFlightConfiguration: DisplayCaptureConfiguration?
    package var lastConfigurationSwitchTimeNs: UInt64?

    package init(
        committedConfiguration: DisplayCaptureConfiguration,
        demand: DisplayCaptureDemandSnapshot,
        captureSizeContext: DisplayCaptureSizeContext = .defaultShared,
        lastConfigurationSwitchTimeNs: UInt64? = nil
    ) {
        self.demand = demand
        self.captureSizeContext = captureSizeContext
        self.committedConfiguration = committedConfiguration
        self.lastConfigurationSwitchTimeNs = lastConfigurationSwitchTimeNs
    }

    mutating func updateDemand(
        _ demand: DisplayCaptureDemandSnapshot,
        nowNs: UInt64,
        minimumDwellNanoseconds: UInt64
    ) -> DisplayCaptureConfigurationDecision {
        self.demand = demand
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
                captureSizeContext: captureSizeContext
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
    nonisolated func stopSharing()
    nonisolated func setDemand(_ demand: DisplayCaptureDemandSnapshot) async throws
    nonisolated func captureMetricsSnapshot() -> DisplayCaptureMetricsSnapshot
    nonisolated func stop() async
}

package extension DisplayCaptureSessioning {
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
