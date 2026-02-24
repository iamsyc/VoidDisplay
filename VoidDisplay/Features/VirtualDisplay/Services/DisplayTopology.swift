import CoreGraphics
import OSLog

struct DisplayTopologySnapshot: Equatable {
    struct DisplayInfo: Equatable {
        let id: CGDirectDisplayID
        let serialNumber: UInt32
        let isManagedVirtualDisplay: Bool
        let isActive: Bool
        let isInMirrorSet: Bool
        let mirrorMasterDisplayID: CGDirectDisplayID?
        let bounds: CGRect
    }

    let mainDisplayID: CGDirectDisplayID
    let displays: [DisplayInfo]

    func display(for id: CGDirectDisplayID) -> DisplayInfo? {
        displays.first(where: { $0.id == id })
    }
}

extension DisplayTopologySnapshot.DisplayInfo {
    var isViable: Bool {
        isActive && bounds.width > 1 && bounds.height > 1
    }
}

protocol DisplayTopologyInspecting {
    func snapshot(
        trackedManagedSerials: Set<UInt32>,
        managedVendorID: UInt32,
        managedProductID: UInt32
    ) -> DisplayTopologySnapshot?
}

protocol DisplayTopologyRepairing {
    func repair(
        snapshot: DisplayTopologySnapshot,
        managedDisplayIDs: [CGDirectDisplayID],
        anchorDisplayID: CGDirectDisplayID
    ) -> Bool
}

func makeSystemManagedDisplayOnlineChecker(
    managedVendorID: UInt32,
    managedProductID: UInt32
) -> (UInt32) -> Bool {
    { serialNum in
        systemOnlineDisplayIDs().contains { displayID in
            CGDisplayVendorNumber(displayID) == managedVendorID &&
            CGDisplayModelNumber(displayID) == managedProductID &&
            CGDisplaySerialNumber(displayID) == serialNum
        }
    }
}

private func systemOnlineDisplayIDs() -> [CGDirectDisplayID] {
    var displayCount: UInt32 = 0
    let preflight = CGGetOnlineDisplayList(0, nil, &displayCount)
    guard preflight == .success, displayCount > 0 else {
        return []
    }

    var ids = Array(repeating: CGDirectDisplayID(), count: Int(displayCount))
    var resolvedCount: UInt32 = 0
    let status = CGGetOnlineDisplayList(displayCount, &ids, &resolvedCount)
    guard status == .success else {
        return []
    }
    return Array(ids.prefix(Int(resolvedCount)))
}

struct SystemDisplayTopologyInspector: DisplayTopologyInspecting {
    func snapshot(
        trackedManagedSerials: Set<UInt32>,
        managedVendorID: UInt32,
        managedProductID: UInt32
    ) -> DisplayTopologySnapshot? {
        var displayCount: UInt32 = 0
        let preflight = CGGetOnlineDisplayList(0, nil, &displayCount)
        guard preflight == .success else { return nil }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        var resolvedCount: UInt32 = 0
        let listStatus = CGGetOnlineDisplayList(displayCount, &displayIDs, &resolvedCount)
        guard listStatus == .success else { return nil }

        let infos = displayIDs.prefix(Int(resolvedCount)).map { displayID in
            let vendorID = CGDisplayVendorNumber(displayID)
            let productID = CGDisplayModelNumber(displayID)
            let serialNumber = CGDisplaySerialNumber(displayID)
            let mirrorMaster = CGDisplayMirrorsDisplay(displayID)
            return DisplayTopologySnapshot.DisplayInfo(
                id: displayID,
                serialNumber: serialNumber,
                isManagedVirtualDisplay: vendorID == managedVendorID &&
                    productID == managedProductID &&
                    trackedManagedSerials.contains(serialNumber),
                isActive: CGDisplayIsActive(displayID) != 0,
                isInMirrorSet: CGDisplayIsInMirrorSet(displayID) != 0,
                mirrorMasterDisplayID: mirrorMaster == kCGNullDirectDisplay ? nil : mirrorMaster,
                bounds: CGDisplayBounds(displayID)
            )
        }
        .sorted { $0.id < $1.id }

        return DisplayTopologySnapshot(
            mainDisplayID: CGMainDisplayID(),
            displays: infos
        )
    }
}

struct SystemDisplayTopologyRepairer: DisplayTopologyRepairing {
    private let horizontalSpacing: Int32 = 80

    func repair(
        snapshot: DisplayTopologySnapshot,
        managedDisplayIDs: [CGDirectDisplayID],
        anchorDisplayID: CGDirectDisplayID
    ) -> Bool {
        let uniqueManagedDisplayIDs = Array(Set(managedDisplayIDs)).sorted()
        guard !uniqueManagedDisplayIDs.isEmpty else { return false }

        var displayConfig: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&displayConfig) == .success,
              let displayConfig else {
            AppLog.virtualDisplay.error("Topology repair failed: CGBeginDisplayConfiguration failed.")
            return false
        }

        func fail() -> Bool {
            CGCancelDisplayConfiguration(displayConfig)
            AppLog.virtualDisplay.error("Topology repair cancelled due to intermediate failure.")
            return false
        }

        for displayID in uniqueManagedDisplayIDs {
            let status = CGConfigureDisplayMirrorOfDisplay(
                displayConfig,
                displayID,
                kCGNullDirectDisplay
            )
            guard status == .success else {
                AppLog.virtualDisplay.error(
                    "Topology repair failed while clearing mirror (displayID: \(displayID, privacy: .public), status: \(status.rawValue, privacy: .public))."
                )
                return fail()
            }
        }

        let placementAnchorID: CGDirectDisplayID

        if uniqueManagedDisplayIDs.contains(anchorDisplayID) {
            placementAnchorID = anchorDisplayID
        } else if let firstManaged = uniqueManagedDisplayIDs.first {
            placementAnchorID = firstManaged
        } else {
            return fail()
        }
        let placementOrder = orderedDisplayIDs(
            anchorDisplayID: placementAnchorID,
            managedDisplayIDs: uniqueManagedDisplayIDs,
            snapshot: snapshot
        )

        let baselineY: Int32 = 0
        var nextX: Int32 = 0

        for displayID in placementOrder {
            if let currentMode = CGDisplayCopyDisplayMode(displayID) {
                _ = CGConfigureDisplayWithDisplayMode(
                    displayConfig,
                    displayID,
                    currentMode,
                    nil
                )
            }

            let originStatus = CGConfigureDisplayOrigin(
                displayConfig,
                displayID,
                nextX,
                baselineY
            )
            guard originStatus == .success else {
                AppLog.virtualDisplay.error(
                    "Topology repair failed while setting origin (displayID: \(displayID, privacy: .public), x: \(nextX, privacy: .public), y: \(baselineY, privacy: .public), status: \(originStatus.rawValue, privacy: .public))."
                )
                return fail()
            }

            guard let bounds = bounds(for: displayID, snapshot: snapshot) else {
                return fail()
            }
            guard let afterWidth = safeAdd(nextX, toInt32(bounds.width)),
                  let afterSpacing = safeAdd(afterWidth, horizontalSpacing) else {
                return fail()
            }
            nextX = afterSpacing
        }

        let completeStatus = CGCompleteDisplayConfiguration(displayConfig, .forSession)
        if completeStatus != .success {
            AppLog.virtualDisplay.error(
                "Topology repair commit failed (status: \(completeStatus.rawValue, privacy: .public))."
            )
            return false
        }
        return true
    }

    private func orderedDisplayIDs(
        anchorDisplayID: CGDirectDisplayID,
        managedDisplayIDs: [CGDirectDisplayID],
        snapshot: DisplayTopologySnapshot
    ) -> [CGDirectDisplayID] {
        let trailingIDs = managedDisplayIDs
            .filter { $0 != anchorDisplayID }
            .sorted { lhs, rhs in
                let lhsBounds = bounds(for: lhs, snapshot: snapshot) ?? .zero
                let rhsBounds = bounds(for: rhs, snapshot: snapshot) ?? .zero
                if lhsBounds.origin.x != rhsBounds.origin.x {
                    return lhsBounds.origin.x < rhsBounds.origin.x
                }
                if lhsBounds.origin.y != rhsBounds.origin.y {
                    return lhsBounds.origin.y < rhsBounds.origin.y
                }
                return lhs < rhs
            }
        return [anchorDisplayID] + trailingIDs
    }

    private func bounds(
        for displayID: CGDirectDisplayID,
        snapshot: DisplayTopologySnapshot
    ) -> CGRect? {
        if let sampled = snapshot.display(for: displayID) {
            return sampled.bounds
        }
        return nil
    }

    private func toInt32(_ value: CGFloat) -> Int32 {
        let rounded = value.rounded()
        let lowerBound = CGFloat(Int32.min)
        let upperBound = CGFloat(Int32.max)
        return Int32(min(max(rounded, lowerBound), upperBound))
    }

    private func safeAdd(_ lhs: Int32, _ rhs: Int32) -> Int32? {
        lhs.addingReportingOverflow(rhs).overflow ? nil : lhs + rhs
    }
}
