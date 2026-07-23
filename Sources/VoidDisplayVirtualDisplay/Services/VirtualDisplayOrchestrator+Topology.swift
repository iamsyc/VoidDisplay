import Foundation
import OSLog
import VoidDisplayObservability

@MainActor
extension VirtualDisplayOrchestrator {
    // MARK: - Topology

    func currentTopologySnapshot() -> DisplayTopologySnapshot? {
        topologyInspector.snapshot(
            trackedManagedSerials: trackedManagedSerials(),
            managedVendorID: ManagedVirtualDisplayIdentity.vendorID,
            managedProductID: ManagedVirtualDisplayIdentity.productID
        )
    }

    private func trackedManagedSerials() -> Set<UInt32> {
        Set(configManager.allConfigs().map(\.serialNum))
            .union(runtimeTracker.activeSerialNumbers)
    }

    // MARK: - Adaptive cooldown

    func waitForAdaptiveManagedDisplayCooldown(
        serialNumbers: [UInt32],
        maxCooldown: TimeInterval
    ) async -> VirtualDisplayAdaptiveCooldownResult {
        let targetSerials = Set(serialNumbers)
        guard !targetSerials.isEmpty, maxCooldown > 0 else {
            return VirtualDisplayAdaptiveCooldownResult(waitedSeconds: 0, completedEarly: true)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = clock.now() + max(maxCooldown, 0)
        let pollInterval = min(
            VirtualDisplayTimingPolicy.adaptiveCooldownPollIntervalCeiling,
            max(VirtualDisplayTimingPolicy.adaptiveCooldownPollIntervalFloor, topologyStabilityPollInterval / 4)
        )
        var stableAbsenceSamples = 0

        while clock.now() < deadline {
            if let snapshot = currentTopologySnapshot() {
                let managedTargetsVisible = snapshot.displays.contains { display in
                    display.isManagedVirtualDisplay && targetSerials.contains(display.serialNumber)
                }
                if managedTargetsVisible {
                    stableAbsenceSamples = 0
                } else {
                    stableAbsenceSamples += 1
                    if stableAbsenceSamples >= VirtualDisplayTimingPolicy.adaptiveCooldownStableSamplesRequired {
                        let waitedMs = elapsedMilliseconds(since: start)
                        return VirtualDisplayAdaptiveCooldownResult(
                            waitedSeconds: Double(waitedMs) / 1000,
                            completedEarly: true
                        )
                    }
                }
            } else {
                stableAbsenceSamples = 0
            }
            await clock.sleep(for: .seconds(pollInterval))
        }

        let waitedMs = elapsedMilliseconds(since: start)
        return VirtualDisplayAdaptiveCooldownResult(
            waitedSeconds: Double(waitedMs) / 1000,
            completedEarly: false
        )
    }

    // MARK: - Logging

    func logTopologySnapshot(
        _ label: String,
        snapshot: DisplayTopologySnapshot?
    ) {
        guard let snapshot else {
            AppLog.virtualDisplay.debug("\(label, privacy: .public): snapshot=nil")
            return
        }
        AppLog.virtualDisplay.debug(
            "\(label, privacy: .public): \(self.describe(snapshot: snapshot), privacy: .public)"
        )
    }

    private func describe(snapshot: DisplayTopologySnapshot) -> String {
        let displaysDescription = snapshot.displays.map { display in
            let mainMarker = display.id == snapshot.mainDisplayID ? "*" : ""
            let mirrorMaster = display.mirrorMasterDisplayID.map(String.init) ?? "-"
            let bounds = display.bounds
            let roundedBounds = "\(Int(bounds.origin.x.rounded())):\(Int(bounds.origin.y.rounded())):\(Int(bounds.width.rounded()))x\(Int(bounds.height.rounded()))"
            return [
                "\(mainMarker)\(display.id)",
                "s\(display.serialNumber)",
                display.isManagedVirtualDisplay ? "M" : "P",
                display.isActive ? "A" : "I",
                display.isInMirrorSet ? "mir" : "nomir",
                "master:\(mirrorMaster)",
                "b:\(roundedBounds)"
            ].joined(separator: "/")
        }
        return "main=\(snapshot.mainDisplayID) displays=[\(displaysDescription.joined(separator: ", "))]"
    }

    private func elapsedMilliseconds(since startNanoseconds: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= startNanoseconds ? (now - startNanoseconds) / 1_000_000 : 0
    }

}
