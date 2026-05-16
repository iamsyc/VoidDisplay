import Foundation

package nonisolated struct DisplayRuntimeConsumerLeaseID: Codable, Equatable, Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

package nonisolated struct DisplaySurfaceEpoch: Codable, Comparable, Equatable, Hashable, Sendable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = max(1, rawValue)
    }

    package static let initial = Self(rawValue: 1)

    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    package func advanced() -> Self {
        Self(rawValue: rawValue + 1)
    }
}

package nonisolated enum DisplaySurfaceConsumerKind: String, Codable, Equatable, Hashable, Sendable {
    case preview
    case lanWebView
    case diagnosticsRecorder
}

package nonisolated enum DisplayRuntimeConsumerOwnerSource: String, Codable, Equatable, Hashable, Sendable {
    case localUI
    case sharingService
    case diagnostics
    case runtimeTest
}

package nonisolated struct DisplayRuntimeConsumerOwner: Codable, Equatable, Hashable, Sendable {
    package let source: DisplayRuntimeConsumerOwnerSource
    package let redactedLabel: String?

    package init(
        source: DisplayRuntimeConsumerOwnerSource,
        redactedLabel: String? = nil
    ) {
        self.source = source
        self.redactedLabel = redactedLabel
    }
}

package nonisolated enum DisplayRuntimeConsumerLeaseState: String, Codable, Equatable, Sendable {
    case attaching
    case attached
    case restarting
    case draining
    case released
    case failed

    package var contributesDemand: Bool {
        switch self {
        case .attaching, .attached:
            true
        case .restarting, .draining, .released, .failed:
            false
        }
    }
}

package nonisolated struct DisplayRuntimeConsumerLease: Codable, Equatable, Sendable {
    package let id: DisplayRuntimeConsumerLeaseID
    package let surfaceIdentity: DisplaySurfaceIdentity
    package let surfaceEpoch: DisplaySurfaceEpoch
    package let resolvedDisplayID: DisplayRuntimeDisplayID?
    package let kind: DisplaySurfaceConsumerKind
    package let owner: DisplayRuntimeConsumerOwner
    package let createdAt: Date
    package let updatedAt: Date
    package let state: DisplayRuntimeConsumerLeaseState
    package let demand: DisplayRuntimeConsumerDemand
    package let lastFailureCode: String?

    package init(
        id: DisplayRuntimeConsumerLeaseID = .init(),
        surfaceIdentity: DisplaySurfaceIdentity,
        surfaceEpoch: DisplaySurfaceEpoch,
        resolvedDisplayID: DisplayRuntimeDisplayID?,
        kind: DisplaySurfaceConsumerKind,
        owner: DisplayRuntimeConsumerOwner,
        createdAt: Date,
        updatedAt: Date,
        state: DisplayRuntimeConsumerLeaseState,
        demand: DisplayRuntimeConsumerDemand,
        lastFailureCode: String? = nil
    ) {
        self.id = id
        self.surfaceIdentity = surfaceIdentity
        self.surfaceEpoch = surfaceEpoch
        self.resolvedDisplayID = resolvedDisplayID
        self.kind = kind
        self.owner = owner
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.demand = demand
        self.lastFailureCode = lastFailureCode
    }
}
