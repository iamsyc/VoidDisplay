import CoreGraphics
import Foundation

struct TopologyHealthEvaluation {
    enum Issue {
        case managedDisplaysCollapsedIntoSingleMirrorSet
        case managedDisplaysOverlappingInExtendedSpace
        case mainDisplayOutsideManagedSetWithoutPhysicalFallback
    }

    let issue: Issue?
    let managedDisplayIDs: [CGDirectDisplayID]
    let forceNormalization: Bool

    var needsRepair: Bool { issue != nil }
}

enum TopologyHealthEvaluator {
    static func evaluate(
        snapshot: DisplayTopologySnapshot,
        desiredManagedSerials: Set<UInt32>
    ) -> TopologyHealthEvaluation {
        let managedDisplays = snapshot.displays.filter(\.isManagedVirtualDisplay)
        let managedDisplayIDs = managedDisplays.map(\.id).sorted()
        let desiredManagedDisplays = managedDisplays.filter { desiredManagedSerials.contains($0.serialNumber) }
        let desiredManagedDisplayIDs = desiredManagedDisplays.map(\.id)
        let hasPhysicalDisplay = snapshot.displays.contains {
            !$0.isManagedVirtualDisplay && $0.isViable
        }
        let forceNormalization = !hasPhysicalDisplay &&
            desiredManagedSerials.count >= 2 &&
            desiredManagedDisplayIDs.count >= 2

        if desiredManagedSerials.count >= 2 &&
            desiredManagedDisplayIDs.count >= 2 &&
            areManagedDisplaysCollapsedIntoSingleMirrorSet(
                snapshot: snapshot,
                managedDisplayIDs: desiredManagedDisplayIDs
            ) {
            return TopologyHealthEvaluation(
                issue: .managedDisplaysCollapsedIntoSingleMirrorSet,
                managedDisplayIDs: managedDisplayIDs,
                forceNormalization: forceNormalization
            )
        }

        if desiredManagedSerials.count >= 2 &&
            desiredManagedDisplays.count >= 2 &&
            areManagedDisplaysOverlappingInExtendedSpace(desiredManagedDisplays) {
            return TopologyHealthEvaluation(
                issue: .managedDisplaysOverlappingInExtendedSpace,
                managedDisplayIDs: managedDisplayIDs,
                forceNormalization: forceNormalization
            )
        }

        let mainInManagedSet = managedDisplayIDs.contains(snapshot.mainDisplayID)
        if !hasPhysicalDisplay && !mainInManagedSet {
            return TopologyHealthEvaluation(
                issue: .mainDisplayOutsideManagedSetWithoutPhysicalFallback,
                managedDisplayIDs: managedDisplayIDs,
                forceNormalization: forceNormalization
            )
        }

        return TopologyHealthEvaluation(
            issue: nil,
            managedDisplayIDs: managedDisplayIDs,
            forceNormalization: forceNormalization
        )
    }

    static func managedDisplayID(
        for serialNum: UInt32,
        snapshot: DisplayTopologySnapshot?
    ) -> CGDirectDisplayID? {
        guard let snapshot else { return nil }
        if let activeManagedDisplay = snapshot.displays.first(where: {
            $0.isManagedVirtualDisplay &&
                $0.serialNumber == serialNum &&
                $0.isViable
        }) {
            return activeManagedDisplay.id
        }
        return snapshot.displays.first(where: {
            $0.isManagedVirtualDisplay &&
                $0.serialNumber == serialNum
        })?.id
    }

    static func selectRepairAnchorDisplayID(
        snapshot: DisplayTopologySnapshot,
        managedDisplayIDs: [CGDirectDisplayID],
        preferredMainDisplayID: CGDirectDisplayID? = nil
    ) -> CGDirectDisplayID {
        let uniqueManagedDisplayIDs = Array(Set(managedDisplayIDs)).sorted()
        guard !uniqueManagedDisplayIDs.isEmpty else {
            return snapshot.mainDisplayID
        }
        if let preferredMainDisplayID,
           uniqueManagedDisplayIDs.contains(preferredMainDisplayID),
           let preferredMain = snapshot.display(for: preferredMainDisplayID),
           preferredMain.isViable {
            return preferredMainDisplayID
        }
        if uniqueManagedDisplayIDs.contains(snapshot.mainDisplayID),
           let main = snapshot.display(for: snapshot.mainDisplayID),
           main.isViable {
            return snapshot.mainDisplayID
        }

        let orderedCandidates = uniqueManagedDisplayIDs.sorted { lhs, rhs in
            let lhsBounds = snapshot.display(for: lhs)?.bounds ?? .zero
            let rhsBounds = snapshot.display(for: rhs)?.bounds ?? .zero
            if lhsBounds.origin.x != rhsBounds.origin.x {
                return lhsBounds.origin.x < rhsBounds.origin.x
            }
            if lhsBounds.origin.y != rhsBounds.origin.y {
                return lhsBounds.origin.y < rhsBounds.origin.y
            }
            return lhs < rhs
        }
        return orderedCandidates.first ?? uniqueManagedDisplayIDs[0]
    }

    static func preferredManagedMainDisplayID(
        snapshot: DisplayTopologySnapshot?
    ) -> CGDirectDisplayID? {
        guard let snapshot,
              let mainDisplay = snapshot.display(for: snapshot.mainDisplayID),
              mainDisplay.isManagedVirtualDisplay,
              mainDisplay.isViable else {
            return nil
        }
        return snapshot.mainDisplayID
    }

    static func shouldEnforceMainContinuity(
        preferredMainDisplayID: CGDirectDisplayID,
        snapshot: DisplayTopologySnapshot,
        managedDisplayIDs: [CGDirectDisplayID]
    ) -> Bool {
        guard snapshot.mainDisplayID != preferredMainDisplayID else { return false }
        guard managedDisplayIDs.contains(preferredMainDisplayID) else { return false }
        guard let preferredMain = snapshot.display(for: preferredMainDisplayID),
              preferredMain.isViable else {
            return false
        }
        let hasPhysicalDisplay = snapshot.displays.contains {
            !$0.isManagedVirtualDisplay && $0.isViable
        }
        return !hasPhysicalDisplay
    }

    private static func areManagedDisplaysCollapsedIntoSingleMirrorSet(
        snapshot: DisplayTopologySnapshot,
        managedDisplayIDs: [CGDirectDisplayID]
    ) -> Bool {
        let uniqueManagedIDs = Array(Set(managedDisplayIDs))
        guard uniqueManagedIDs.count >= 2 else { return false }

        // On some macOS transitions the mirror root may not report `isInMirrorSet == true`
        // while mirrored dependents do. Treat any mirror relationship as a collapsed candidate.
        let hasMirrorRelationship = uniqueManagedIDs.contains { id in
            guard let display = snapshot.display(for: id) else { return false }
            return display.isInMirrorSet || display.mirrorMasterDisplayID != nil
        }
        guard hasMirrorRelationship else { return false }

        let roots = Set(uniqueManagedIDs.map { mirrorRoot(for: $0, snapshot: snapshot) })
        return roots.count == 1
    }

    private static func areManagedDisplaysOverlappingInExtendedSpace(
        _ managedDisplays: [DisplayTopologySnapshot.DisplayInfo]
    ) -> Bool {
        guard managedDisplays.count >= 2 else { return false }
        var signatures: Set<String> = []
        for display in managedDisplays {
            let bounds = display.bounds
            let signature = [
                Int(bounds.origin.x.rounded()),
                Int(bounds.origin.y.rounded()),
                Int(bounds.width.rounded()),
                Int(bounds.height.rounded())
            ]
            .map(String.init)
            .joined(separator: ":")
            if !signatures.insert(signature).inserted {
                return true
            }
        }
        return false
    }

    private static func mirrorRoot(
        for displayID: CGDirectDisplayID,
        snapshot: DisplayTopologySnapshot
    ) -> CGDirectDisplayID {
        var current = displayID
        var visited: Set<CGDirectDisplayID> = []

        while let display = snapshot.display(for: current),
              let mirrorMaster = display.mirrorMasterDisplayID,
              mirrorMaster != current,
              !visited.contains(current) {
            visited.insert(current)
            current = mirrorMaster
        }

        return current
    }
}
