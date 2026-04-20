import Foundation

struct CaptureSnapshotProvider: ObservabilitySnapshotProvider, @unchecked Sendable {
    nonisolated struct Snapshot: Codable, Equatable, Sendable {
        nonisolated struct Metrics: Codable, Equatable, Sendable {
            let currentProfile: String?
            let currentFrameRateTier: String?
            let receivedFrameCount: UInt64
            let profileReconfigurationCount: UInt64
            let cursorOverrideReconfigurationCount: UInt64
        }

        nonisolated struct Session: Codable, Equatable, Sendable {
            let id: UUID
            let displayID: UInt32
            let displayName: String
            let resolutionText: String
            let isVirtualDisplay: Bool
            let capturesCursor: Bool
            let state: String
            let metrics: Metrics
        }

        let startingDisplayIDs: [UInt32]
        let sessions: [Session]
    }

    let key = "capture"
    private unowned let controller: CaptureController

    init(controller: CaptureController) {
        self.controller = controller
    }

    @MainActor
    func makeSnapshot() -> Snapshot {
        Snapshot(
            startingDisplayIDs: controller.startingDisplayIDs.sorted(),
            sessions: controller.screenCaptureSessions.map { session in
                let metrics = session.previewSubscription.captureMetricsSnapshot()
                return .init(
                    id: session.id,
                    displayID: session.displayID,
                    displayName: session.displayName,
                    resolutionText: session.resolutionText,
                    isVirtualDisplay: session.isVirtualDisplay,
                    capturesCursor: session.capturesCursor,
                    state: session.state == .starting ? "starting" : "active",
                    metrics: .init(
                        currentProfile: metrics.currentProfile?.rawValue,
                        currentFrameRateTier: metrics.currentFrameRateTier.map { "\($0.framesPerSecond)fps" },
                        receivedFrameCount: metrics.receivedFrameCount,
                        profileReconfigurationCount: metrics.profileReconfigurationCount,
                        cursorOverrideReconfigurationCount: metrics.cursorOverrideReconfigurationCount
                    )
                )
            }
        )
    }
}
