import Foundation

package nonisolated struct DisplayRuntimeCaptureSnapshot: Codable, Equatable, Sendable {
    package let startingDisplayIDs: [DisplayRuntimeDisplayID]
    package let sessions: [DisplayRuntimeCaptureSession]

    package init(
        startingDisplayIDs: [DisplayRuntimeDisplayID],
        sessions: [DisplayRuntimeCaptureSession]
    ) {
        self.startingDisplayIDs = startingDisplayIDs.sorted()
        self.sessions = sessions.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    package static let empty = Self(startingDisplayIDs: [], sessions: [])
}

package nonisolated struct DisplayRuntimeCaptureSession: Codable, Equatable, Sendable {
    package let id: UUID
    package let displayID: DisplayRuntimeDisplayID
    package let isVirtualDisplay: Bool
    package let capturesCursor: Bool
    package let state: DisplayRuntimeCaptureSessionState
    package let metrics: DisplayRuntimeCaptureMetrics

    package init(
        id: UUID,
        displayID: DisplayRuntimeDisplayID,
        isVirtualDisplay: Bool,
        capturesCursor: Bool,
        state: DisplayRuntimeCaptureSessionState,
        metrics: DisplayRuntimeCaptureMetrics
    ) {
        self.id = id
        self.displayID = displayID
        self.isVirtualDisplay = isVirtualDisplay
        self.capturesCursor = capturesCursor
        self.state = state
        self.metrics = metrics
    }
}

package nonisolated enum DisplayRuntimeCaptureSessionState: String, Codable, Equatable, Sendable {
    case starting
    case active
}

package nonisolated struct DisplayRuntimeCaptureMetrics: Codable, Equatable, Sendable {
    package let currentProfile: String?
    package let currentFrameRateTier: String?
    package let receivedFrameCount: UInt64
    package let profileReconfigurationCount: UInt64
    package let cursorOverrideReconfigurationCount: UInt64

    package init(
        currentProfile: String?,
        currentFrameRateTier: String?,
        receivedFrameCount: UInt64,
        profileReconfigurationCount: UInt64,
        cursorOverrideReconfigurationCount: UInt64
    ) {
        self.currentProfile = currentProfile
        self.currentFrameRateTier = currentFrameRateTier
        self.receivedFrameCount = receivedFrameCount
        self.profileReconfigurationCount = profileReconfigurationCount
        self.cursorOverrideReconfigurationCount = cursorOverrideReconfigurationCount
    }

    package static let empty = Self(
        currentProfile: nil,
        currentFrameRateTier: nil,
        receivedFrameCount: 0,
        profileReconfigurationCount: 0,
        cursorOverrideReconfigurationCount: 0
    )
}
