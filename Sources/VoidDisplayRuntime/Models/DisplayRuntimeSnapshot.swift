import Foundation

package nonisolated struct DisplayRuntimeSnapshot: Codable, Equatable, Sendable {
    package let schemaVersion: Int
    package let surfaces: [DisplaySurface]
    package let catalog: DisplayRuntimeCatalogSnapshot
    package let capture: DisplayRuntimeCaptureSnapshot
    package let sharing: DisplayRuntimeSharingSnapshot
    package let virtualDisplay: DisplayRuntimeVirtualDisplaySnapshot
    package let transactions: DisplayRuntimeTransactionSnapshot
    package let consumerLeases: [DisplayRuntimeConsumerLeaseSnapshot]
    package let aggregatedDemands: [DisplayRuntimeAggregatedDemand]
    package let effectiveCaptureIntents: [DisplayRuntimeEffectiveCaptureIntent]
    package let consumerSummary: DisplayRuntimeConsumerSummarySnapshot

    package init(
        schemaVersion: Int = 4,
        surfaces: [DisplaySurface],
        catalog: DisplayRuntimeCatalogSnapshot,
        capture: DisplayRuntimeCaptureSnapshot,
        sharing: DisplayRuntimeSharingSnapshot,
        virtualDisplay: DisplayRuntimeVirtualDisplaySnapshot,
        transactions: DisplayRuntimeTransactionSnapshot = .empty,
        consumerLeases: [DisplayRuntimeConsumerLeaseSnapshot] = [],
        aggregatedDemands: [DisplayRuntimeAggregatedDemand] = [],
        effectiveCaptureIntents: [DisplayRuntimeEffectiveCaptureIntent] = [],
        surfaceEpochs: [DisplayRuntimeSurfaceEpochSnapshot] = [],
        latestCaptureIntentRevision: DisplayRuntimeCaptureIntentRevision? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.surfaces = surfaces.sorted {
            ($0.kind.rawValue, $0.identity.stableID) < ($1.kind.rawValue, $1.identity.stableID)
        }
        self.catalog = catalog
        self.capture = capture
        self.sharing = sharing
        self.virtualDisplay = virtualDisplay
        self.transactions = transactions
        self.consumerLeases = consumerLeases.sorted(by: Self.consumerLeaseSort)
        self.aggregatedDemands = aggregatedDemands.sorted(by: Self.aggregatedDemandSort)
        self.effectiveCaptureIntents = effectiveCaptureIntents.sorted(by: Self.effectiveCaptureIntentSort)
        self.consumerSummary = DisplayRuntimeConsumerSummarySnapshot(
            consumerLeases: self.consumerLeases,
            aggregatedDemands: self.aggregatedDemands,
            surfaceEpochs: surfaceEpochs,
            latestCaptureIntentRevision: latestCaptureIntentRevision
        )
    }

    package static let empty = Self(
        surfaces: [],
        catalog: .empty,
        capture: .empty,
        sharing: .empty,
        virtualDisplay: .empty,
        transactions: .empty
    )

    private static func consumerLeaseSort(
        lhs: DisplayRuntimeConsumerLeaseSnapshot,
        rhs: DisplayRuntimeConsumerLeaseSnapshot
    ) -> Bool {
        if lhs.surfaceIdentity.kind != rhs.surfaceIdentity.kind {
            return lhs.surfaceIdentity.kind.rawValue < rhs.surfaceIdentity.kind.rawValue
        }
        if lhs.surfaceIdentity.stableID != rhs.surfaceIdentity.stableID {
            return lhs.surfaceIdentity.stableID < rhs.surfaceIdentity.stableID
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }

    private static func aggregatedDemandSort(
        lhs: DisplayRuntimeAggregatedDemand,
        rhs: DisplayRuntimeAggregatedDemand
    ) -> Bool {
        if lhs.surfaceIdentity.kind != rhs.surfaceIdentity.kind {
            return lhs.surfaceIdentity.kind.rawValue < rhs.surfaceIdentity.kind.rawValue
        }
        return lhs.surfaceIdentity.stableID < rhs.surfaceIdentity.stableID
    }

    private static func effectiveCaptureIntentSort(
        lhs: DisplayRuntimeEffectiveCaptureIntent,
        rhs: DisplayRuntimeEffectiveCaptureIntent
    ) -> Bool {
        if lhs.intent.surfaceIdentity.kind != rhs.intent.surfaceIdentity.kind {
            return lhs.intent.surfaceIdentity.kind.rawValue < rhs.intent.surfaceIdentity.kind.rawValue
        }
        if lhs.intent.surfaceIdentity.stableID != rhs.intent.surfaceIdentity.stableID {
            return lhs.intent.surfaceIdentity.stableID < rhs.intent.surfaceIdentity.stableID
        }
        return lhs.intent.revision < rhs.intent.revision
    }
}

package nonisolated struct DisplayRuntimeConsumerLeaseSnapshot: Codable, Equatable, Sendable {
    package let id: DisplayRuntimeConsumerLeaseID
    package let surfaceIdentity: DisplaySurfaceIdentity
    package let surfaceEpoch: DisplaySurfaceEpoch
    package let resolvedDisplayID: DisplayRuntimeDisplayID?
    package let kind: DisplaySurfaceConsumerKind
    package let ownerSource: DisplayRuntimeConsumerOwnerSource
    package let createdAt: Date
    package let updatedAt: Date
    package let state: DisplayRuntimeConsumerLeaseState
    package let demand: DisplayRuntimeConsumerDemand
    package let lastFailureCode: String?

    package init(lease: DisplayRuntimeConsumerLease) {
        self.id = lease.id
        self.surfaceIdentity = lease.surfaceIdentity
        self.surfaceEpoch = lease.surfaceEpoch
        self.resolvedDisplayID = lease.resolvedDisplayID
        self.kind = lease.kind
        self.ownerSource = lease.owner.source
        self.createdAt = lease.createdAt
        self.updatedAt = lease.updatedAt
        self.state = lease.state
        self.demand = lease.demand
        self.lastFailureCode = lease.lastFailureCode
    }
}

package nonisolated struct DisplayRuntimeSurfaceEpochSnapshot: Codable, Equatable, Sendable {
    package let surfaceIdentity: DisplaySurfaceIdentity
    package let surfaceEpoch: DisplaySurfaceEpoch

    package init(
        surfaceIdentity: DisplaySurfaceIdentity,
        surfaceEpoch: DisplaySurfaceEpoch
    ) {
        self.surfaceIdentity = surfaceIdentity
        self.surfaceEpoch = surfaceEpoch
    }
}

package nonisolated struct DisplayRuntimeConsumerKindLeaseCount: Codable, Equatable, Sendable {
    package let kind: DisplaySurfaceConsumerKind
    package let activeCount: Int
    package let totalCount: Int

    package init(
        kind: DisplaySurfaceConsumerKind,
        activeCount: Int,
        totalCount: Int
    ) {
        self.kind = kind
        self.activeCount = max(0, activeCount)
        self.totalCount = max(0, totalCount)
    }
}

package nonisolated struct DisplayRuntimeConsumerSummarySnapshot: Codable, Equatable, Sendable {
    package let leaseCountsByKind: [DisplayRuntimeConsumerKindLeaseCount]
    package let activeLeaseCount: Int
    package let totalLeaseCount: Int
    package let activeViewerCount: Int
    package let latestCaptureIntentRevision: DisplayRuntimeCaptureIntentRevision?
    package let surfaceEpochs: [DisplayRuntimeSurfaceEpochSnapshot]

    package init(
        consumerLeases: [DisplayRuntimeConsumerLeaseSnapshot],
        aggregatedDemands: [DisplayRuntimeAggregatedDemand],
        surfaceEpochs: [DisplayRuntimeSurfaceEpochSnapshot],
        latestCaptureIntentRevision: DisplayRuntimeCaptureIntentRevision?
    ) {
        self.leaseCountsByKind = Self.makeLeaseCountsByKind(from: consumerLeases)
        self.activeLeaseCount = consumerLeases.filter { $0.state.contributesDemand }.count
        self.totalLeaseCount = consumerLeases.count
        self.activeViewerCount = aggregatedDemands.reduce(0) { $0 + $1.activeViewerCount }
        self.latestCaptureIntentRevision = latestCaptureIntentRevision
        self.surfaceEpochs = surfaceEpochs.sorted {
            if $0.surfaceIdentity.kind != $1.surfaceIdentity.kind {
                return $0.surfaceIdentity.kind.rawValue < $1.surfaceIdentity.kind.rawValue
            }
            return $0.surfaceIdentity.stableID < $1.surfaceIdentity.stableID
        }
    }

    private static func makeLeaseCountsByKind(
        from consumerLeases: [DisplayRuntimeConsumerLeaseSnapshot]
    ) -> [DisplayRuntimeConsumerKindLeaseCount] {
        Dictionary(grouping: consumerLeases, by: \.kind)
            .map { kind, leases in
                DisplayRuntimeConsumerKindLeaseCount(
                    kind: kind,
                    activeCount: leases.filter { $0.state.contributesDemand }.count,
                    totalCount: leases.count
                )
            }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
    }
}
