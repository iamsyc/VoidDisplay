import CoreGraphics
import Foundation
import Testing
@testable import FreelyDisplay

struct VirtualDisplayTopologyRecoveryTests {

    @MainActor
    @Test func disablingMainManagedDisplayWithoutFallbackIsBlocked() throws {
        let managedMainID: CGDirectDisplayID = 101
        let snapshot = topologySnapshot(
            mainDisplayID: managedMainID,
            displays: [
                displayInfo(id: managedMainID, serial: 1, managed: true)
            ]
        )
        let inspector = FakeDisplayTopologyInspector(snapshots: [snapshot])
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(inspector: inspector, repairer: repairer)
        service.replaceDisplayConfigsForTesting([
            config(serial: 1, desiredEnabled: true)
        ])

        do {
            try service.validateDisableSafetyForTesting(
                runtimeDisplayID: managedMainID,
                treatAsMainDisplay: true
            )
            Issue.record("Expected disable safety to block with no fallback display.")
        } catch let error as VirtualDisplayService.VirtualDisplayError {
            guard case .cannotDisableCurrentMainWithoutFallback = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @MainActor
    @Test func disablingMainManagedDisplayFailsClosedWhenTopologySamplingUnavailable() {
        let managedMainID: CGDirectDisplayID = 111
        let inspector = FakeDisplayTopologyInspector(snapshots: [])
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(inspector: inspector, repairer: repairer)
        service.replaceDisplayConfigsForTesting([
            config(serial: 1, desiredEnabled: true)
        ])

        do {
            try service.validateDisableSafetyForTesting(
                runtimeDisplayID: managedMainID,
                treatAsMainDisplay: true
            )
            Issue.record("Expected fail-closed behavior when topology sampling is unavailable.")
        } catch let error as VirtualDisplayService.VirtualDisplayError {
            guard case .disableSafetyCheckUnavailable = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @MainActor
    @Test func disablingMainManagedDisplayAllowsAnotherManagedFallback() throws {
        let managedMainID: CGDirectDisplayID = 101
        let managedFallbackID: CGDirectDisplayID = 102
        let snapshot = topologySnapshot(
            mainDisplayID: managedMainID,
            displays: [
                displayInfo(id: managedMainID, serial: 1, managed: true),
                displayInfo(id: managedFallbackID, serial: 2, managed: true)
            ]
        )
        let inspector = FakeDisplayTopologyInspector(snapshots: [snapshot])
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(inspector: inspector, repairer: repairer)
        service.replaceDisplayConfigsForTesting([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try service.validateDisableSafetyForTesting(
            runtimeDisplayID: managedMainID,
            treatAsMainDisplay: true
        )
    }

    @MainActor
    @Test func postEnableMirrorCollapseTriggersRepairAndKeepsCurrentMainAsAnchor() async throws {
        let displayA: CGDirectDisplayID = 201
        let displayB: CGDirectDisplayID = 202

        let collapsed = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, inMirrorSet: true, mirrorMasterID: displayB),
                displayInfo(id: displayB, serial: 2, managed: true, inMirrorSet: true, mirrorMasterID: nil)
            ]
        )
        let expanded = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true),
                displayInfo(id: displayB, serial: 2, managed: true)
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [collapsed, collapsed, collapsed, expanded, expanded, expanded]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.08,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigsForTesting([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try await service.ensureHealthyTopologyAfterEnableForTesting()

        #expect(repairer.callCount == 1)
        #expect(repairer.lastAnchorDisplayID == displayB)
        #expect(Set(repairer.lastManagedDisplayIDs) == Set([displayA, displayB]))
    }

    @MainActor
    @Test func postEnableRepairFailureThrowsTopologyRepairFailed() async {
        let displayA: CGDirectDisplayID = 301
        let displayB: CGDirectDisplayID = 302

        let collapsed = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, inMirrorSet: true, mirrorMasterID: displayB),
                displayInfo(id: displayB, serial: 2, managed: true, inMirrorSet: true, mirrorMasterID: nil)
            ]
        )

        let inspector = FakeDisplayTopologyInspector(snapshots: [collapsed, collapsed, collapsed])
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: false)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.05,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigsForTesting([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        do {
            try await service.ensureHealthyTopologyAfterEnableForTesting()
            Issue.record("Expected topology repair to fail.")
        } catch let error as VirtualDisplayService.VirtualDisplayError {
            guard case .topologyRepairFailed = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @MainActor
    @Test func regressionScenarioAReEnableWithoutDisablingBRecoversExpandedTopology() async throws {
        let displayA: CGDirectDisplayID = 401
        let displayB: CGDirectDisplayID = 402

        let collapsedAfterAReenable = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, inMirrorSet: true, mirrorMasterID: displayB),
                displayInfo(id: displayB, serial: 2, managed: true, inMirrorSet: true, mirrorMasterID: nil)
            ]
        )
        let recoveredExpanded = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true),
                displayInfo(id: displayB, serial: 2, managed: true)
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [
                collapsedAfterAReenable,
                collapsedAfterAReenable,
                collapsedAfterAReenable,
                recoveredExpanded,
                recoveredExpanded,
                recoveredExpanded
            ]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.08,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigsForTesting([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try await service.ensureHealthyTopologyAfterEnableForTesting()
        #expect(repairer.callCount == 1)
    }

    @MainActor
    @Test func postEnableMainOutsideManagedWithoutPhysicalFallbackTriggersRepair() async throws {
        let displayA: CGDirectDisplayID = 501
        let displayB: CGDirectDisplayID = 502
        let nonManagedMain: CGDirectDisplayID = 999

        let broken = topologySnapshot(
            mainDisplayID: nonManagedMain,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true),
                displayInfo(id: displayB, serial: 2, managed: true)
            ]
        )
        let recovered = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true),
                displayInfo(id: displayB, serial: 2, managed: true)
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [broken, broken, broken, recovered, recovered, recovered]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.08,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigsForTesting([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try await service.ensureHealthyTopologyAfterEnableForTesting()
        #expect(repairer.callCount == 1)
        #expect(repairer.lastAnchorDisplayID == nonManagedMain)
    }

    @MainActor
    @Test func postEnableThrowsTopologyUnstableWhenTopologyNeverSettles() async {
        let first = topologySnapshot(
            mainDisplayID: 601,
            displays: [
                displayInfo(id: 601, serial: 1, managed: true)
            ]
        )
        let second = topologySnapshot(
            mainDisplayID: 602,
            displays: [
                displayInfo(id: 602, serial: 1, managed: true)
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [first, second],
            sequenceMode: .cycle
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.01,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigsForTesting([
            config(serial: 1, desiredEnabled: true)
        ])

        do {
            try await service.ensureHealthyTopologyAfterEnableForTesting()
            Issue.record("Expected topology unstable error.")
        } catch let error as VirtualDisplayService.VirtualDisplayError {
            guard case .topologyUnstableAfterEnable = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @MainActor
    @Test func postEnableThrowsTopologyUnstableOnAABBOscillation() async {
        let first = topologySnapshot(
            mainDisplayID: 701,
            displays: [
                displayInfo(id: 701, serial: 1, managed: true)
            ]
        )
        let second = topologySnapshot(
            mainDisplayID: 702,
            displays: [
                displayInfo(id: 702, serial: 1, managed: true)
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [first, first, second, second],
            sequenceMode: .cycle
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.02,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigsForTesting([
            config(serial: 1, desiredEnabled: true)
        ])

        do {
            try await service.ensureHealthyTopologyAfterEnableForTesting()
            Issue.record("Expected topology unstable error for A/A/B/B oscillation.")
        } catch let error as VirtualDisplayService.VirtualDisplayError {
            guard case .topologyUnstableAfterEnable = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @MainActor
    @Test func postEnableFailureRollbackClearsRunningStateAndKeepsGenerationUntilTermination() async {
        let snapshot = topologySnapshot(
            mainDisplayID: 801,
            displays: [
                displayInfo(id: 801, serial: 1, managed: true)
            ]
        )
        let inspector = FakeDisplayTopologyInspector(snapshots: [snapshot])
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(inspector: inspector, repairer: repairer)

        let configId = UUID()
        service.seedRuntimeBookkeepingForTesting(configId: configId, generation: 42)

        await service.simulateEnablePostTopologyFailureRollbackForTesting(
            configId: configId,
            serialNum: 1,
            offlineTimeout: 0
        )

        let state = service.runtimeBookkeepingForTesting(configId: configId)
        #expect(state.isRunning == false)
        #expect(state.generation == 42)
    }

    @MainActor
    private func makeService(
        inspector: any DisplayTopologyInspecting,
        repairer: any DisplayTopologyRepairing,
        topologyStabilityTimeout: TimeInterval = 0.05,
        topologyStabilityPollInterval: TimeInterval = 0.001
    ) -> VirtualDisplayService {
        VirtualDisplayService(
            persistenceService: nil,
            displayReconfigurationMonitor: FakeDisplayReconfigurationMonitor(),
            topologyInspector: inspector,
            topologyRepairer: repairer,
            managedDisplayOnlineChecker: { _ in false },
            topologyStabilityTimeout: topologyStabilityTimeout,
            topologyStabilityPollInterval: topologyStabilityPollInterval
        )
    }

    private func config(serial: UInt32, desiredEnabled: Bool) -> VirtualDisplayConfig {
        VirtualDisplayConfig(
            name: "Managed \(serial)",
            serialNum: serial,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [
                .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
            ],
            desiredEnabled: desiredEnabled
        )
    }

    private func topologySnapshot(
        mainDisplayID: CGDirectDisplayID,
        displays: [DisplayTopologySnapshot.DisplayInfo]
    ) -> DisplayTopologySnapshot {
        DisplayTopologySnapshot(
            mainDisplayID: mainDisplayID,
            displays: displays.sorted { $0.id < $1.id }
        )
    }

    private func displayInfo(
        id: CGDirectDisplayID,
        serial: UInt32,
        managed: Bool,
        inMirrorSet: Bool = false,
        mirrorMasterID: CGDirectDisplayID? = nil,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    ) -> DisplayTopologySnapshot.DisplayInfo {
        DisplayTopologySnapshot.DisplayInfo(
            id: id,
            serialNumber: serial,
            isManagedVirtualDisplay: managed,
            isInMirrorSet: inMirrorSet,
            mirrorMasterDisplayID: mirrorMasterID,
            bounds: bounds
        )
    }
}

private final class FakeDisplayTopologyInspector: DisplayTopologyInspecting {
    enum SequenceMode {
        case repeatLast
        case cycle
    }

    private let snapshots: [DisplayTopologySnapshot]
    private let sequenceMode: SequenceMode
    private var callIndex = 0

    init(
        snapshots: [DisplayTopologySnapshot],
        sequenceMode: SequenceMode = .repeatLast
    ) {
        self.snapshots = snapshots
        self.sequenceMode = sequenceMode
    }

    func snapshot(
        trackedManagedSerials: Set<UInt32>,
        managedVendorID: UInt32,
        managedProductID: UInt32
    ) -> DisplayTopologySnapshot? {
        guard !snapshots.isEmpty else { return nil }
        let index: Int
        switch sequenceMode {
        case .repeatLast:
            index = min(callIndex, snapshots.count - 1)
        case .cycle:
            index = callIndex % snapshots.count
        }
        callIndex += 1
        return snapshots[index]
    }
}

private final class FakeDisplayTopologyRepairer: DisplayTopologyRepairing {
    private let shouldSucceed: Bool

    private(set) var callCount = 0
    private(set) var lastManagedDisplayIDs: [CGDirectDisplayID] = []
    private(set) var lastAnchorDisplayID: CGDirectDisplayID?

    init(shouldSucceed: Bool) {
        self.shouldSucceed = shouldSucceed
    }

    func repair(
        snapshot: DisplayTopologySnapshot,
        managedDisplayIDs: [CGDirectDisplayID],
        anchorDisplayID: CGDirectDisplayID
    ) -> Bool {
        callCount += 1
        lastManagedDisplayIDs = managedDisplayIDs
        lastAnchorDisplayID = anchorDisplayID
        return shouldSucceed
    }
}

private final class FakeDisplayReconfigurationMonitor: DisplayReconfigurationMonitoring {
    @discardableResult
    func start(handler: @escaping @MainActor () -> Void) -> Bool {
        true
    }

    func stop() {}
}
