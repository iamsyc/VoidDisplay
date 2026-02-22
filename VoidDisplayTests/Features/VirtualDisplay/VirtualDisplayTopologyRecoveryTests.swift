import CoreGraphics
import Foundation
import Testing
@testable import VoidDisplay

@Suite(.serialized)
struct VirtualDisplayTopologyRecoveryTests {

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
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [collapsed, collapsed, collapsed, expanded, expanded, expanded]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.2,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigsForTesting([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try await service.ensureHealthyTopologyAfterEnableForTesting()

        #expect(repairer.callCount == 2)
        #expect(repairer.lastAnchorDisplayID == displayB)
        #expect(Set(repairer.lastManagedDisplayIDs) == Set([displayA, displayB]))
    }

    @MainActor
    @Test func postEnableOverlappingManagedDisplaysWithoutMirrorFlagsTriggersRepair() async throws {
        let hiddenMain: CGDirectDisplayID = 290
        let displayA: CGDirectDisplayID = 291
        let displayB: CGDirectDisplayID = 292

        let collapsed = topologySnapshot(
            mainDisplayID: hiddenMain,
            displays: [
                displayInfo(
                    id: hiddenMain,
                    serial: 90,
                    managed: false,
                    bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
                ),
                displayInfo(
                    id: displayA,
                    serial: 1,
                    managed: true,
                    bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
                ),
                displayInfo(
                    id: displayB,
                    serial: 2,
                    managed: true,
                    bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
                )
            ]
        )
        let recovered = topologySnapshot(
            mainDisplayID: hiddenMain,
            displays: [
                displayInfo(
                    id: hiddenMain,
                    serial: 90,
                    managed: false,
                    bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
                ),
                displayInfo(
                    id: displayA,
                    serial: 1,
                    managed: true,
                    bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
                ),
                displayInfo(
                    id: displayB,
                    serial: 2,
                    managed: true,
                    bounds: CGRect(x: 3920, y: 0, width: 1920, height: 1080)
                )
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [collapsed, collapsed, collapsed, recovered, recovered, recovered]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.2,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigsForTesting([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try await service.ensureHealthyTopologyAfterEnableForTesting()
        #expect(repairer.callCount == 1)
        #expect(Set(repairer.lastManagedDisplayIDs) == Set([displayA, displayB]))
    }

    @MainActor
    @Test func postEnableUsesPreferredManagedMainForContinuityWhenSystemMainDrifts() async throws {
        let displayA: CGDirectDisplayID = 701
        let displayB: CGDirectDisplayID = 702

        let collapsedOnA = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, inMirrorSet: true, mirrorMasterID: nil),
                displayInfo(id: displayB, serial: 2, managed: true, inMirrorSet: true, mirrorMasterID: displayA)
            ]
        )
        let expandedButStillMainA = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )
        let expandedRecoveredToB = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [
                collapsedOnA, collapsedOnA, collapsedOnA,
                expandedButStillMainA, expandedButStillMainA, expandedButStillMainA,
                expandedButStillMainA, expandedButStillMainA, expandedButStillMainA,
                expandedRecoveredToB, expandedRecoveredToB, expandedRecoveredToB
            ]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.25,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigsForTesting([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try await service.ensureHealthyTopologyAfterEnableForTesting(preferredMainDisplayID: displayB)
        #expect(repairer.callCount == 3)
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
            topologyStabilityTimeout: 0.25,
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
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
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
            topologyStabilityTimeout: 0.2,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigsForTesting([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try await service.ensureHealthyTopologyAfterEnableForTesting()
        #expect(repairer.callCount == 2)
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
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [broken, broken, broken, recovered, recovered, recovered]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.2,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigsForTesting([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try await service.ensureHealthyTopologyAfterEnableForTesting()
        #expect(repairer.callCount == 2)
        #expect(repairer.lastAnchorDisplayID == displayB)
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
            topologyStabilityTimeout: 0.05,
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
            topologyStabilityTimeout: 0.08,
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
    @Test func rebuildInvokesTopologyRecoveryAndPreservesManagedMainContinuity() async throws {
        let displayA: CGDirectDisplayID = 901
        let displayB: CGDirectDisplayID = 902

        let configA = config(id: UUID(), serial: 1, desiredEnabled: true)
        let configB = config(id: UUID(), serial: 2, desiredEnabled: true)

        let collapsedAfterRebuild = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, inMirrorSet: true, mirrorMasterID: nil),
                displayInfo(id: displayB, serial: 2, managed: true, inMirrorSet: true, mirrorMasterID: displayA)
            ]
        )
        let recoveredExpanded = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )

        var rebuildHookCallCount = 0
        let inspector = FakeDisplayTopologyInspector(
            snapshots: [
                collapsedAfterRebuild, collapsedAfterRebuild, collapsedAfterRebuild,
                recoveredExpanded, recoveredExpanded, recoveredExpanded,
                recoveredExpanded, recoveredExpanded, recoveredExpanded
            ]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.25,
            topologyStabilityPollInterval: 0.001,
            rebuildRuntimeDisplayHook: { rebuiltConfig, terminationConfirmed in
                rebuildHookCallCount += 1
                #expect(rebuiltConfig.id == configA.id)
                #expect(terminationConfirmed)
            }
        )
        service.replaceDisplayConfigsForTesting([configA, configB])

        try await service.rebuildVirtualDisplay(configId: configA.id)

        #expect(rebuildHookCallCount == 1)
        #expect(repairer.callCount == 2)
        #expect(repairer.lastAnchorDisplayID == displayA)
    }

    @MainActor
    @Test func rebuildManagedMainWithMultipleRunningDisplaysUsesCoordinatedFleetRebuildOrder() async throws {
        let displayA: CGDirectDisplayID = 921
        let displayB: CGDirectDisplayID = 922

        let configA = config(id: UUID(), serial: 1, desiredEnabled: true)
        let configB = config(id: UUID(), serial: 2, desiredEnabled: true)
        let expandedStable = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )

        var rebuildOrder: [UUID] = []
        var terminationFlags: [Bool] = []
        let inspector = FakeDisplayTopologyInspector(
            snapshots: [
                expandedStable, expandedStable, expandedStable, expandedStable,
                expandedStable, expandedStable, expandedStable, expandedStable,
                expandedStable, expandedStable, expandedStable, expandedStable
            ]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.25,
            topologyStabilityPollInterval: 0.001,
            rebuildRuntimeDisplayHook: { rebuiltConfig, terminationConfirmed in
                rebuildOrder.append(rebuiltConfig.id)
                terminationFlags.append(terminationConfirmed)
            }
        )
        service.replaceDisplayConfigsForTesting([configA, configB])
        service.seedRuntimeBookkeepingForTesting(configId: configA.id, generation: 11)
        service.seedRuntimeBookkeepingForTesting(configId: configB.id, generation: 12)

        try await service.rebuildVirtualDisplay(configId: configA.id)

        #expect(rebuildOrder == [configA.id, configB.id])
        #expect(terminationFlags == [false, false])
        #expect(repairer.callCount == 2)
    }

    @MainActor
    @Test func rebuildManagedMainUsesCoordinatedFleetWhenInitialSnapshotUnavailable() async throws {
        let displayA: CGDirectDisplayID = CGMainDisplayID()
        let displayB: CGDirectDisplayID = displayA == 0 ? 1 : displayA &+ 1

        let configA = config(id: UUID(), serial: 1, desiredEnabled: true)
        let configB = config(id: UUID(), serial: 2, desiredEnabled: true)
        let expandedStable = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )

        var rebuildOrder: [UUID] = []
        let inspector = NullableDisplayTopologyInspector(
            snapshots: [
                nil,
                expandedStable, expandedStable, expandedStable,
                expandedStable, expandedStable, expandedStable
            ]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.2,
            topologyStabilityPollInterval: 0.001,
            rebuildRuntimeDisplayHook: { rebuiltConfig, _ in
                rebuildOrder.append(rebuiltConfig.id)
            }
        )
        service.replaceDisplayConfigsForTesting([configA, configB])
        service.seedRuntimeBookkeepingForTesting(
            configId: configA.id,
            generation: 21,
            runtimeDisplayID: displayA
        )
        service.seedRuntimeBookkeepingForTesting(
            configId: configB.id,
            generation: 22,
            runtimeDisplayID: displayB
        )

        try await service.rebuildVirtualDisplay(configId: configA.id)

        #expect(rebuildOrder == [configA.id, configB.id])
        #expect(repairer.callCount == 2)
    }

    @MainActor
    @Test func rebuildFailsWhenDisplayRemainsOnlineDuringFinalOfflineConfirmation() async {
        let displayA: CGDirectDisplayID = 911
        let snapshot = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            ]
        )

        let configA = config(serial: 1, desiredEnabled: true)
        var rebuildHookCallCount = 0
        let service = makeService(
            inspector: FakeDisplayTopologyInspector(snapshots: [snapshot]),
            repairer: FakeDisplayTopologyRepairer(shouldSucceed: true),
            managedDisplayOnlineChecker: { _ in true },
            rebuildRuntimeDisplayHook: { _, _ in
                rebuildHookCallCount += 1
            }
        )
        service.replaceDisplayConfigsForTesting([configA])

        do {
            try await service.rebuildVirtualDisplay(configId: configA.id)
            Issue.record("Expected rebuild to fail when display stays online.")
        } catch let error as VirtualDisplayService.VirtualDisplayError {
            guard case .teardownTimedOut = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(rebuildHookCallCount == 0)
    }

    @MainActor
    private func makeService(
        inspector: any DisplayTopologyInspecting,
        repairer: any DisplayTopologyRepairing,
        topologyStabilityTimeout: TimeInterval = 0.2,
        topologyStabilityPollInterval: TimeInterval = 0.001,
        managedDisplayOnlineChecker: @escaping (UInt32) -> Bool = { _ in false },
        rebuildRuntimeDisplayHook: (@MainActor (VirtualDisplayConfig, Bool) async throws -> Void)? = nil
    ) -> VirtualDisplayService {
#if DEBUG
        VirtualDisplayService(
            persistenceService: nil,
            displayReconfigurationMonitor: FakeDisplayReconfigurationMonitor(),
            topologyInspector: inspector,
            topologyRepairer: repairer,
            managedDisplayOnlineChecker: managedDisplayOnlineChecker,
            topologyStabilityTimeout: topologyStabilityTimeout,
            topologyStabilityPollInterval: topologyStabilityPollInterval,
            rebuildRuntimeDisplayHook: rebuildRuntimeDisplayHook
        )
#else
        _ = rebuildRuntimeDisplayHook
        return VirtualDisplayService(
            persistenceService: nil,
            displayReconfigurationMonitor: FakeDisplayReconfigurationMonitor(),
            topologyInspector: inspector,
            topologyRepairer: repairer,
            managedDisplayOnlineChecker: managedDisplayOnlineChecker,
            topologyStabilityTimeout: topologyStabilityTimeout,
            topologyStabilityPollInterval: topologyStabilityPollInterval
        )
#endif
    }

    private func config(id: UUID = UUID(), serial: UInt32, desiredEnabled: Bool) -> VirtualDisplayConfig {
        VirtualDisplayConfig(
            id: id,
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
        isActive: Bool = true,
        inMirrorSet: Bool = false,
        mirrorMasterID: CGDirectDisplayID? = nil,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    ) -> DisplayTopologySnapshot.DisplayInfo {
        DisplayTopologySnapshot.DisplayInfo(
            id: id,
            serialNumber: serial,
            isManagedVirtualDisplay: managed,
            isActive: isActive,
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

private final class NullableDisplayTopologyInspector: DisplayTopologyInspecting {
    private let snapshots: [DisplayTopologySnapshot?]
    private var callIndex = 0

    init(snapshots: [DisplayTopologySnapshot?]) {
        self.snapshots = snapshots
    }

    func snapshot(
        trackedManagedSerials: Set<UInt32>,
        managedVendorID: UInt32,
        managedProductID: UInt32
    ) -> DisplayTopologySnapshot? {
        guard !snapshots.isEmpty else { return nil }
        let index = min(callIndex, snapshots.count - 1)
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
