import Foundation

@MainActor
extension DisplayRuntime {
    func currentDemandLeases(
        for surfaceIdentity: DisplaySurfaceIdentity
    ) -> [DisplayRuntimeConsumerLease] {
        consumerLeasesByID.values
            .filter { $0.surfaceIdentity == surfaceIdentity }
            .filter { $0.state.contributesDemand }
            .sorted(by: leaseSort)
    }

    func currentUnreleasedLeases(
        for surfaceIdentity: DisplaySurfaceIdentity
    ) -> [DisplayRuntimeConsumerLease] {
        consumerLeasesByID.values
            .filter { $0.surfaceIdentity == surfaceIdentity }
            .filter { $0.state != .released }
            .sorted(by: leaseSort)
    }

    func resolvedDisplayID(
        for surfaceIdentity: DisplaySurfaceIdentity,
        surfaces: [DisplaySurface]?
    ) -> DisplayRuntimeDisplayID? {
        if let storedDisplayID = surfaceResolvedDisplayIDs[surfaceIdentity] {
            return storedDisplayID
        }
        if let surfaces {
            return surfaces.first {
                $0.identity == surfaceIdentity
            }?.currentDisplayID
        }
        return makeSnapshot().surfaces.first {
            $0.identity == surfaceIdentity
        }?.currentDisplayID
    }

    func resolvedVisibleDisplayID(
        for surfaceIdentity: DisplaySurfaceIdentity,
        snapshot: DisplayRuntimeSnapshot
    ) -> DisplayRuntimeDisplayID? {
        let visibleDisplayIDs = Set(snapshot.catalog.loadedDisplays.map(\.displayID))
        guard let surface = snapshot.surfaces.first(where: { $0.identity == surfaceIdentity }),
              let displayID = surface.currentDisplayID,
              surface.managedVirtualDisplay?.isRunning != false,
              visibleDisplayIDs.contains(displayID)
        else {
            return nil
        }
        return displayID
    }

    @discardableResult
    func replaceLease(
        _ lease: DisplayRuntimeConsumerLease,
        state: DisplayRuntimeConsumerLeaseState,
        surfaceEpoch: DisplaySurfaceEpoch? = nil,
        resolvedDisplayID: DisplayRuntimeDisplayID?? = nil,
        demand: DisplayRuntimeConsumerDemand?,
        lastFailureCode: String?
    ) -> DisplayRuntimeConsumerLease {
        let now = Date.now
        let updatedAt = now > lease.updatedAt
            ? now
            : lease.updatedAt.addingTimeInterval(0.000_001)
        let updatedLease = DisplayRuntimeConsumerLease(
            id: lease.id,
            surfaceIdentity: lease.surfaceIdentity,
            surfaceEpoch: surfaceEpoch ?? lease.surfaceEpoch,
            resolvedDisplayID: resolvedDisplayID ?? lease.resolvedDisplayID,
            kind: lease.kind,
            owner: lease.owner,
            createdAt: lease.createdAt,
            updatedAt: updatedAt,
            state: state,
            demand: demand ?? lease.demand,
            lastFailureCode: lastFailureCode
        )
        consumerLeasesByID[lease.id] = updatedLease
        return updatedLease
    }

    @discardableResult
    func markConsumerLeaseFailed(
        leaseID: DisplayRuntimeConsumerLeaseID,
        failureCode: String
    ) -> DisplayRuntimeConsumerLease? {
        guard let lease = consumerLeasesByID[leaseID], lease.state != .released else { return nil }
        let failedLease = replaceLease(
            lease,
            state: .failed,
            demand: nil,
            lastFailureCode: failureCode
        )
        notifyPreviewLeaseWaitersIfTerminal(leaseID: leaseID)
        return failedLease
    }

    func notifyPreviewLeaseWaitersIfTerminal(
        leaseID: DisplayRuntimeConsumerLeaseID
    ) {
        guard let lease = terminalPreviewLease(leaseID: leaseID),
              let waiters = previewLeaseWaiters.removeValue(forKey: leaseID)
        else {
            return
        }
        for continuation in waiters.values {
            continuation.resume(returning: lease)
        }
    }

    func terminalPreviewLease(
        leaseID: DisplayRuntimeConsumerLeaseID
    ) -> DisplayRuntimeConsumerLease? {
        guard let lease = consumerLeasesByID[leaseID] else { return nil }
        switch lease.state {
        case .attached, .failed, .released:
            return lease
        case .attaching, .restarting, .draining:
            return nil
        }
    }

    func cancelPreviewLeaseWaiter(
        leaseID: DisplayRuntimeConsumerLeaseID,
        waiterID: UUID
    ) {
        guard let continuation = previewLeaseWaiters[leaseID]?.removeValue(forKey: waiterID) else {
            return
        }
        if previewLeaseWaiters[leaseID]?.isEmpty == true {
            previewLeaseWaiters.removeValue(forKey: leaseID)
        }
        continuation.resume(returning: consumerLeasesByID[leaseID])
    }

    func leaseSort(
        lhs: DisplayRuntimeConsumerLease,
        rhs: DisplayRuntimeConsumerLease
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

    func aggregateDemandSort(
        lhs: DisplayRuntimeAggregatedDemand,
        rhs: DisplayRuntimeAggregatedDemand
    ) -> Bool {
        if lhs.surfaceIdentity.kind != rhs.surfaceIdentity.kind {
            return lhs.surfaceIdentity.kind.rawValue < rhs.surfaceIdentity.kind.rawValue
        }
        return lhs.surfaceIdentity.stableID < rhs.surfaceIdentity.stableID
    }

    func captureIntentSort(
        lhs: DisplayRuntimeCaptureIntent,
        rhs: DisplayRuntimeCaptureIntent
    ) -> Bool {
        if lhs.surfaceIdentity.kind != rhs.surfaceIdentity.kind {
            return lhs.surfaceIdentity.kind.rawValue < rhs.surfaceIdentity.kind.rawValue
        }
        if lhs.surfaceIdentity.stableID != rhs.surfaceIdentity.stableID {
            return lhs.surfaceIdentity.stableID < rhs.surfaceIdentity.stableID
        }
        return lhs.revision < rhs.revision
    }
}
