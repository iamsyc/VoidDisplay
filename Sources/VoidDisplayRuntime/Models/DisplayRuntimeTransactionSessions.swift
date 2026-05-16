import Foundation

package nonisolated struct DisplayRuntimeSessionPauseIntent: Codable, Equatable, Sendable {
    package let surfaceIdentity: DisplaySurfaceIdentity
    package let displayID: DisplayRuntimeDisplayID
    package let pauseSharing: Bool
    package let pausePreview: Bool

    package init(
        surfaceIdentity: DisplaySurfaceIdentity,
        displayID: DisplayRuntimeDisplayID,
        pauseSharing: Bool,
        pausePreview: Bool
    ) {
        self.surfaceIdentity = surfaceIdentity
        self.displayID = displayID
        self.pauseSharing = pauseSharing
        self.pausePreview = pausePreview
    }
}

package nonisolated struct DisplayRuntimeSessionRestoreIntent: Codable, Equatable, Sendable {
    package let surfaceIdentity: DisplaySurfaceIdentity
    package let previousDisplayID: DisplayRuntimeDisplayID?
    package let resolvedDisplayID: DisplayRuntimeDisplayID?
    package let restoreSharing: Bool
    package let restorePreview: Bool
    package let previewCapturesCursor: Bool

    package init(
        surfaceIdentity: DisplaySurfaceIdentity,
        previousDisplayID: DisplayRuntimeDisplayID?,
        resolvedDisplayID: DisplayRuntimeDisplayID?,
        restoreSharing: Bool,
        restorePreview: Bool,
        previewCapturesCursor: Bool
    ) {
        self.surfaceIdentity = surfaceIdentity
        self.previousDisplayID = previousDisplayID
        self.resolvedDisplayID = resolvedDisplayID
        self.restoreSharing = restoreSharing
        self.restorePreview = restorePreview
        self.previewCapturesCursor = previewCapturesCursor
    }
}

package nonisolated enum DisplayRuntimeSessionRestoreKind: String, Codable, Equatable, Sendable {
    case sharing
    case preview
}

package nonisolated enum DisplayRuntimeSessionRestoreStatus: String, Codable, Equatable, Sendable {
    case skipped
    case restored
    case failed
    case invalidated
}

package nonisolated struct DisplayRuntimeSessionRestoreResult: Codable, Equatable, Sendable {
    package let kind: DisplayRuntimeSessionRestoreKind
    package let status: DisplayRuntimeSessionRestoreStatus
    package let previousDisplayID: DisplayRuntimeDisplayID?
    package let resolvedDisplayID: DisplayRuntimeDisplayID?
    package let failureReason: String?

    package init(
        kind: DisplayRuntimeSessionRestoreKind,
        status: DisplayRuntimeSessionRestoreStatus,
        previousDisplayID: DisplayRuntimeDisplayID?,
        resolvedDisplayID: DisplayRuntimeDisplayID?,
        failureReason: String?
    ) {
        self.kind = kind
        self.status = status
        self.previousDisplayID = previousDisplayID
        self.resolvedDisplayID = resolvedDisplayID
        self.failureReason = failureReason
    }
}

package nonisolated struct DisplayRuntimeSharingRestoreCommandResult: Codable, Equatable, Sendable {
    package let status: DisplayRuntimeSessionRestoreStatus
    package let failureReason: String?

    package init(
        status: DisplayRuntimeSessionRestoreStatus,
        failureReason: String?
    ) {
        self.status = status
        self.failureReason = failureReason
    }

    package static let restored = Self(status: .restored, failureReason: nil)

    package static func failed(_ reason: String) -> Self {
        Self(status: .failed, failureReason: reason)
    }

    package static func invalidated(_ reason: String) -> Self {
        Self(status: .invalidated, failureReason: reason)
    }
}
