import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

enum DisplayStartOutcome<Value: Sendable>: Sendable {
    case started(Value)
    case invalidated
}

enum DisplayStartKind: Hashable, Sendable {
    case monitoring
    case sharing
}

nonisolated enum DisplayCaptureProfile: String, Sendable, Equatable {
    case previewOnly
    case shareOnly
    case mixed
}

nonisolated enum DisplayCaptureProfileDecision: Sendable, Equatable {
    case noChange
    case applyNow(DisplayCaptureProfile)
    case applyAfter(DisplayCaptureProfile, delayNanoseconds: UInt64)
}

nonisolated enum DisplayCaptureProfileStateMachine {
    nonisolated static func desiredProfile(
        previewSinkCount: Int,
        sharingActive: Bool
    ) -> DisplayCaptureProfile? {
        switch (previewSinkCount > 0, sharingActive) {
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
        previewSinkCount: Int,
        sharingActive: Bool,
        currentProfile: DisplayCaptureProfile,
        lastProfileSwitchTimeNs: UInt64?,
        nowNs: UInt64,
        minimumDwellNanoseconds: UInt64
    ) -> DisplayCaptureProfileDecision {
        guard let desiredProfile = desiredProfile(
            previewSinkCount: previewSinkCount,
            sharingActive: sharingActive
        ) else {
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

nonisolated struct DisplayCaptureProfileCoordinatorState: Sendable {
    var previewSinkCount: Int = 0
    var sharingActive = false
    var committedProfile: DisplayCaptureProfile
    var inFlightProfile: DisplayCaptureProfile?
    var lastProfileSwitchTimeNs: UInt64?

    nonisolated init(
        committedProfile: DisplayCaptureProfile,
        lastProfileSwitchTimeNs: UInt64? = nil
    ) {
        self.committedProfile = committedProfile
        self.lastProfileSwitchTimeNs = lastProfileSwitchTimeNs
    }

    nonisolated mutating func mutateDemand(
        nowNs: UInt64,
        minimumDwellNanoseconds: UInt64,
        mutation: (inout DisplayCaptureProfileCoordinatorState) -> Void
    ) -> DisplayCaptureProfileDecision {
        mutation(&self)
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
            previewSinkCount: previewSinkCount,
            sharingActive: sharingActive,
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

nonisolated struct DisplayCaptureTaskLifetimeState: Sendable {
    private(set) var currentGeneration: UInt64 = 0

    nonisolated mutating func invalidateAllTasks() -> UInt64 {
        currentGeneration &+= 1
        return currentGeneration
    }

    nonisolated func allowsExecution(for generation: UInt64) -> Bool {
        currentGeneration == generation
    }
}

protocol DisplayPreviewSink: AnyObject, Sendable {
    nonisolated func submitFrame(_ sampleBuffer: CMSampleBuffer)
}

nonisolated struct SendableDisplay: @unchecked Sendable {
    nonisolated(unsafe) let value: SCDisplay
    nonisolated let displayID: CGDirectDisplayID
    nonisolated let width: Int
    nonisolated let height: Int

    nonisolated init(_ value: SCDisplay) {
        self.value = value
        self.displayID = value.displayID
        self.width = value.width
        self.height = value.height
    }
}

struct DisplayCaptureMetricsSnapshot: Sendable {
    var currentProfile: DisplayCaptureProfile?
    var receivedFrameCount: UInt64
    var profileReconfigurationCount: UInt64
    var cursorOverrideReconfigurationCount: UInt64
}

protocol DisplayCaptureSessioning: AnyObject, Sendable {
    nonisolated var sessionHub: WebRTCSessionHub { get }
    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink)
    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink)
    nonisolated func stopSharing()
    nonisolated func setPreviewShowsCursor(_ showsCursor: Bool) async throws
    nonisolated func retainShareCursorOverride() async throws
    nonisolated func releaseShareCursorOverride() async throws
    nonisolated func setSharingActive(_ isActive: Bool) async throws
    nonisolated func captureMetricsSnapshot() -> DisplayCaptureMetricsSnapshot
    nonisolated func stop() async
}

extension DisplayCaptureSessioning {
    nonisolated func setSharingActive(_ isActive: Bool) async throws {
        _ = isActive
    }

    nonisolated func captureMetricsSnapshot() -> DisplayCaptureMetricsSnapshot {
        .init(
            currentProfile: nil,
            receivedFrameCount: 0,
            profileReconfigurationCount: 0,
            cursorOverrideReconfigurationCount: 0
        )
    }
}

struct StartCoordinatorTypeMismatchError: Error {}
