import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import Foundation
import CoreVideo
import Synchronization
package struct DisplayCaptureLeaseBook {
    package enum TokenKind: Sendable {
        case preview
        case share
    }
    package struct PreviewLeaseState: Sendable, Equatable {
        var attachedSinkCount = 0
        var showsCursor = false
    }
    package struct ReleaseResult: Sendable, Equatable {
        let displayID: CGDirectDisplayID
        let shouldStopSharing: Bool
        let shouldApplyDemand: Bool
        let shouldDrainSession: Bool
    }
    package struct PreviewCursorMutation: Sendable, Equatable {
        let displayID: CGDirectDisplayID
        let previousValue: Bool
    }

    private struct TokenRecord: Sendable {
        let kind: TokenKind
        let displayID: CGDirectDisplayID
    }

    private struct PendingCreationDemand: Sendable {
        var previewCount = 0
        var shareCount = 0

        mutating func record(_ kind: TokenKind, delta: Int) {
            switch kind {
            case .preview:
                previewCount = max(0, previewCount + delta)
            case .share:
                shareCount = max(0, shareCount + delta)
            }
        }

        var initialProfile: DisplayCaptureProfile? {
            DisplayCaptureDemandSnapshot(
                attachedPreviewSinkCount: previewCount,
                shareTokenCount: shareCount,
                performanceMode: .automatic
            ).desiredProfile
        }

        var isEmpty: Bool {
            previewCount == 0 && shareCount == 0
        }
    }

    private struct DisplayState {
        var previewTokens: [UUID: PreviewLeaseState] = [:]
        var shareTokens: Set<UUID> = []
        var shareCursorOverrideTokens: Set<UUID> = []
        var hasShareFrameDemand = false

        var hasActiveTokens: Bool {
            previewTokens.isEmpty == false || shareTokens.isEmpty == false
        }
    }

    private var statesByDisplayID: [CGDirectDisplayID: DisplayState] = [:]
    private var tokenOwnership: [UUID: TokenRecord] = [:]
    private var pendingCreationDemandByDisplayID: [CGDirectDisplayID: PendingCreationDemand] = [:]

    mutating func recordPendingCreationDemand(
        for displayID: CGDirectDisplayID,
        kind: TokenKind,
        delta: Int
    ) {
        var demand = pendingCreationDemandByDisplayID[displayID] ?? PendingCreationDemand()
        demand.record(kind, delta: delta)
        if demand.isEmpty {
            pendingCreationDemandByDisplayID.removeValue(forKey: displayID)
        } else {
            pendingCreationDemandByDisplayID[displayID] = demand
        }
    }

    func initialProfile(
        for displayID: CGDirectDisplayID,
        fallbackKind: TokenKind
    ) -> DisplayCaptureProfile {
        if let profile = pendingCreationDemandByDisplayID[displayID]?.initialProfile {
            return profile
        }

        switch fallbackKind {
        case .preview:
            return .previewOnly
        case .share:
            return .shareOnly
        }
    }

    mutating func registerToken(displayID: CGDirectDisplayID, kind: TokenKind) -> UUID {
        let tokenID = UUID()
        var state = statesByDisplayID[displayID] ?? DisplayState()
        switch kind {
        case .preview:
            state.previewTokens[tokenID] = PreviewLeaseState()
        case .share:
            state.shareTokens.insert(tokenID)
        }
        statesByDisplayID[displayID] = state
        tokenOwnership[tokenID] = TokenRecord(kind: kind, displayID: displayID)
        return tokenID
    }

    mutating func releaseToken(_ tokenID: UUID, expectedKind: TokenKind) -> ReleaseResult? {
        guard let ownership = tokenOwnership.removeValue(forKey: tokenID),
              ownership.kind == expectedKind else {
            return nil
        }

        var state = statesByDisplayID[ownership.displayID] ?? DisplayState()
        switch ownership.kind {
        case .preview:
            state.previewTokens.removeValue(forKey: tokenID)
        case .share:
            state.shareTokens.remove(tokenID)
            if state.shareTokens.isEmpty {
                state.hasShareFrameDemand = false
            }
        }
        state.shareCursorOverrideTokens.remove(tokenID)

        let shouldDrainSession = state.hasActiveTokens == false
        let shouldStopSharing = ownership.kind == .share && state.shareTokens.isEmpty
        let shouldApplyDemand = shouldDrainSession == false

        if state.previewTokens.isEmpty && state.shareTokens.isEmpty && state.shareCursorOverrideTokens.isEmpty {
            statesByDisplayID.removeValue(forKey: ownership.displayID)
        } else {
            statesByDisplayID[ownership.displayID] = state
        }

        return ReleaseResult(
            displayID: ownership.displayID,
            shouldStopSharing: shouldStopSharing,
            shouldApplyDemand: shouldApplyDemand,
            shouldDrainSession: shouldDrainSession
        )
    }

    mutating func recordAttachedPreviewSinkDelta(_ delta: Int, for tokenID: UUID) -> CGDirectDisplayID? {
        guard let ownership = tokenOwnership[tokenID],
              ownership.kind == .preview,
              var state = statesByDisplayID[ownership.displayID],
              var lease = state.previewTokens[tokenID] else {
            return nil
        }
        lease.attachedSinkCount = max(0, lease.attachedSinkCount + delta)
        state.previewTokens[tokenID] = lease
        statesByDisplayID[ownership.displayID] = state
        return ownership.displayID
    }

    mutating func setShareFrameDemand(
        _ hasDemand: Bool,
        for displayID: CGDirectDisplayID
    ) -> Bool {
        guard var state = statesByDisplayID[displayID] else { return false }
        let effectiveDemand = hasDemand && !state.shareTokens.isEmpty
        guard state.hasShareFrameDemand != effectiveDemand else { return false }
        state.hasShareFrameDemand = effectiveDemand
        statesByDisplayID[displayID] = state
        return true
    }

    mutating func setPreviewShowsCursor(
        _ showsCursor: Bool,
        for tokenID: UUID
    ) -> PreviewCursorMutation? {
        guard let ownership = tokenOwnership[tokenID],
              ownership.kind == .preview,
              var state = statesByDisplayID[ownership.displayID],
              var lease = state.previewTokens[tokenID] else {
            return nil
        }
        let previousValue = lease.showsCursor
        guard previousValue != showsCursor else { return nil }

        lease.showsCursor = showsCursor
        state.previewTokens[tokenID] = lease
        statesByDisplayID[ownership.displayID] = state
        return PreviewCursorMutation(displayID: ownership.displayID, previousValue: previousValue)
    }

    mutating func revertPreviewShowsCursor(for tokenID: UUID, previousValue: Bool) {
        guard let ownership = tokenOwnership[tokenID],
              ownership.kind == .preview,
              var state = statesByDisplayID[ownership.displayID],
              var lease = state.previewTokens[tokenID] else {
            return
        }
        lease.showsCursor = previousValue
        state.previewTokens[tokenID] = lease
        statesByDisplayID[ownership.displayID] = state
    }

    mutating func prepareShareForSharing(_ tokenID: UUID) -> CGDirectDisplayID? {
        guard let ownership = tokenOwnership[tokenID],
              ownership.kind == .share,
              var state = statesByDisplayID[ownership.displayID] else {
            return nil
        }
        guard state.shareCursorOverrideTokens.contains(tokenID) == false else { return nil }

        state.shareCursorOverrideTokens.insert(tokenID)
        statesByDisplayID[ownership.displayID] = state
        return ownership.displayID
    }

    mutating func revertPreparedShare(_ tokenID: UUID) {
        guard let ownership = tokenOwnership[tokenID],
              ownership.kind == .share,
              var state = statesByDisplayID[ownership.displayID] else {
            return
        }
        guard state.shareCursorOverrideTokens.remove(tokenID) != nil else { return }
        statesByDisplayID[ownership.displayID] = state
    }

    mutating func releasePreparedShare(_ tokenID: UUID) -> CGDirectDisplayID? {
        guard let ownership = tokenOwnership[tokenID],
              ownership.kind == .share,
              var state = statesByDisplayID[ownership.displayID] else {
            return nil
        }
        guard state.shareCursorOverrideTokens.remove(tokenID) != nil else { return nil }
        statesByDisplayID[ownership.displayID] = state
        return ownership.displayID
    }

    func demandSnapshot(
        for displayID: CGDirectDisplayID,
        performanceMode: CapturePerformanceMode
    ) -> DisplayCaptureDemandSnapshot {
        let state = statesByDisplayID[displayID] ?? DisplayState()
        return DisplayCaptureDemandSnapshot(
            attachedPreviewSinkCount: state.previewTokens.values.reduce(0) { partialResult, lease in
                partialResult + lease.attachedSinkCount
            },
            shareTokenCount: state.hasShareFrameDemand ? state.shareTokens.count : 0,
            previewShowsCursor: state.previewTokens.values.contains { $0.showsCursor },
            shareCursorOverrideCount: state.shareCursorOverrideTokens.count,
            performanceMode: performanceMode
        )
    }

    func hasActiveTokens(for displayID: CGDirectDisplayID) -> Bool {
        statesByDisplayID[displayID]?.hasActiveTokens == true
    }
}
