import Foundation

package nonisolated struct DisplayRuntimeSharingSnapshot: Codable, Equatable, Sendable {
    package let activeSharingDisplayIDs: [DisplayRuntimeDisplayID]
    package let startingDisplayIDs: [DisplayRuntimeDisplayID]
    package let isSharing: Bool
    package let isWebServiceRunning: Bool
    package let preferredPort: UInt16?
    package let sharingClientCount: Int
    package let sharingClientCounts: [DisplayRuntimeDisplayClientCount]
    package let lifecycle: DisplayRuntimeSharingLifecycle
    package let routes: [DisplayRuntimeShareRoute]

    package init(
        activeSharingDisplayIDs: [DisplayRuntimeDisplayID],
        startingDisplayIDs: [DisplayRuntimeDisplayID],
        isSharing: Bool,
        isWebServiceRunning: Bool,
        preferredPort: UInt16?,
        sharingClientCount: Int,
        sharingClientCounts: [DisplayRuntimeDisplayClientCount],
        lifecycle: DisplayRuntimeSharingLifecycle,
        routes: [DisplayRuntimeShareRoute]
    ) {
        self.activeSharingDisplayIDs = activeSharingDisplayIDs.sorted()
        self.startingDisplayIDs = startingDisplayIDs.sorted()
        self.isSharing = isSharing
        self.isWebServiceRunning = isWebServiceRunning
        self.preferredPort = preferredPort
        self.sharingClientCount = sharingClientCount
        self.sharingClientCounts = sharingClientCounts.sorted { $0.displayID < $1.displayID }
        self.lifecycle = lifecycle
        self.routes = routes.sorted { $0.displayID < $1.displayID }
    }

    package static let empty = Self(
        activeSharingDisplayIDs: [],
        startingDisplayIDs: [],
        isSharing: false,
        isWebServiceRunning: false,
        preferredPort: nil,
        sharingClientCount: 0,
        sharingClientCounts: [],
        lifecycle: .unavailable,
        routes: []
    )
}

package nonisolated struct DisplayRuntimeDisplayClientCount: Codable, Equatable, Sendable {
    package let displayID: DisplayRuntimeDisplayID
    package let count: Int

    package init(displayID: DisplayRuntimeDisplayID, count: Int) {
        self.displayID = displayID
        self.count = count
    }
}

package nonisolated struct DisplayRuntimeShareRoute: Codable, Equatable, Sendable {
    package let displayID: DisplayRuntimeDisplayID
    package let hasConcreteRoute: Bool

    package init(displayID: DisplayRuntimeDisplayID, hasConcreteRoute: Bool) {
        self.displayID = displayID
        self.hasConcreteRoute = hasConcreteRoute
    }
}

package nonisolated struct DisplayRuntimeSharingLifecycle: Codable, Equatable, Sendable {
    package let phase: DisplayRuntimeSharingLifecyclePhase
    package let requestedPort: UInt16?
    package let boundPort: UInt16?
    package let failureReason: String?
    package let hasFailureMessage: Bool

    package init(
        phase: DisplayRuntimeSharingLifecyclePhase,
        requestedPort: UInt16?,
        boundPort: UInt16?,
        failureReason: String?,
        hasFailureMessage: Bool
    ) {
        self.phase = phase
        self.requestedPort = requestedPort
        self.boundPort = boundPort
        self.failureReason = failureReason
        self.hasFailureMessage = hasFailureMessage
    }

    package static let unavailable = Self(
        phase: .unavailable,
        requestedPort: nil,
        boundPort: nil,
        failureReason: nil,
        hasFailureMessage: false
    )
}

package nonisolated enum DisplayRuntimeSharingLifecyclePhase: String, Codable, Equatable, Sendable {
    case unavailable
    case stopped
    case starting
    case running
    case stopping
    case failed
}
