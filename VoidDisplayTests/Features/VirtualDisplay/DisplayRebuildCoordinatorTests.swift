import CoreGraphics
import Foundation
import Testing
@testable import VoidDisplay

@MainActor
@Suite(.serialized)
struct DisplayRebuildCoordinatorTests {
    @Test
    func ensureHealthyTopologyMirrorCollapseTriggersRepairAndKeepsCurrentMainAsAnchor() async throws {
        let displayA: CGDirectDisplayID = 201
        let displayB: CGDirectDisplayID = 202
        let collapsed = makeSnapshot(
            main: displayB,
            displays: [
                makeDisplayInfo(id: displayA, serial: 1, managed: true, inMirrorSet: true, mirrorMasterID: displayB),
                makeDisplayInfo(id: displayB, serial: 2, managed: true, inMirrorSet: true, mirrorMasterID: nil)
            ]
        )
        let expanded = makeSnapshot(
            main: displayB,
            displays: [
                makeDisplayInfo(id: displayA, serial: 1, managed: true),
                makeDisplayInfo(
                    id: displayB,
                    serial: 2,
                    managed: true,
                    bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
                )
            ]
        )
        let harness = makeHarness(
            configs: [makeConfig(serial: 1, desiredEnabled: true), makeConfig(serial: 2, desiredEnabled: true)],
            snapshots: [collapsed, collapsed, collapsed, expanded, expanded, expanded]
        )

        try await harness.coordinator.ensureHealthyTopologyAfterEnable()

        #expect(harness.repairer.callCount >= 1)
        #expect(harness.repairer.lastAnchorDisplayID == displayB)
        #expect(Set(harness.repairer.lastManagedDisplayIDs) == Set([displayA, displayB]))
    }

    @Test
    func ensureHealthyTopologyFastModeSkipsRepairForStablePureVirtualTopology() async throws {
        let displayA: CGDirectDisplayID = 490
        let displayB: CGDirectDisplayID = 491
        let expanded = makeSnapshot(
            main: displayB,
            displays: [
                makeDisplayInfo(id: displayA, serial: 1, managed: true),
                makeDisplayInfo(
                    id: displayB,
                    serial: 2,
                    managed: true,
                    bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
                )
            ]
        )
        let harness = makeHarness(
            configs: [makeConfig(serial: 1, desiredEnabled: true), makeConfig(serial: 2, desiredEnabled: true)],
            snapshots: [expanded, expanded, expanded]
        )

        try await harness.coordinator.ensureHealthyTopologyAfterEnable(recoveryMode: .fast)

        #expect(harness.repairer.callCount == 0)
    }

    @Test
    func rebuildVirtualDisplayUsesCoordinatedFleetWhenTargetIsManagedMain() async throws {
        let mainID = CGMainDisplayID()
        let secondID: CGDirectDisplayID = mainID == 0 ? 1 : mainID &+ 1

        let configA = makeConfig(serial: 1, desiredEnabled: true)
        let configB = makeConfig(serial: 2, desiredEnabled: true)
        let stableSnapshot = makeSnapshot(
            main: mainID,
            displays: [
                makeDisplayInfo(id: mainID, serial: 1, managed: true),
                makeDisplayInfo(id: secondID, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )

        var rebuiltOrder: [UUID] = []
        var terminationFlags: [Bool] = []
        let harness = makeHarness(
            configs: [configA, configB],
            snapshots: Array(repeating: stableSnapshot, count: 120),
            hook: { config, terminationConfirmed, runtimeTracker in
                rebuiltOrder.append(config.id)
                terminationFlags.append(terminationConfirmed)
                let runtimeID = config.id == configA.id ? mainID : secondID
                runtimeTracker.markConfigRunning(
                    configId: config.id,
                    generation: UInt64(100 + rebuiltOrder.count),
                    runtimeDisplayID: runtimeID
                )
            }
        )
        harness.runtimeTracker.markConfigRunning(configId: configA.id, generation: 11, runtimeDisplayID: mainID)
        harness.runtimeTracker.markConfigRunning(configId: configB.id, generation: 12, runtimeDisplayID: secondID)

        try await harness.coordinator.rebuildVirtualDisplay(configId: configA.id)

        #expect(rebuiltOrder == [configA.id, configB.id])
        #expect(terminationFlags == [false, false])
    }

    @Test
    func rebuildVirtualDisplaySingleTargetUsesQuickOfflineBranch() async throws {
        let targetID: CGDirectDisplayID = 811
        let mainID: CGDirectDisplayID = 999

        let config = makeConfig(serial: 11, desiredEnabled: true)
        let stableSnapshot = makeSnapshot(
            main: mainID,
            displays: [
                makeDisplayInfo(id: targetID, serial: 11, managed: true),
                makeDisplayInfo(id: mainID, serial: 90, managed: false, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )

        var hookTerminationFlag: Bool?
        let harness = makeHarness(
            configs: [config],
            snapshots: Array(repeating: stableSnapshot, count: 80),
            hook: { rebuiltConfig, terminationConfirmed, runtimeTracker in
                hookTerminationFlag = terminationConfirmed
                runtimeTracker.markConfigRunning(
                    configId: rebuiltConfig.id,
                    generation: 201,
                    runtimeDisplayID: targetID
                )
            }
        )
        harness.runtimeTracker.markConfigRunning(configId: config.id, generation: 99, runtimeDisplayID: targetID)

        try await harness.coordinator.rebuildVirtualDisplay(configId: config.id)

        #expect(hookTerminationFlag == false)
    }

    @Test
    func ensureHealthyTopologyRepairsMainContinuityWhenPreferredMainDrifts() async throws {
        let displayA: CGDirectDisplayID = 901
        let displayB: CGDirectDisplayID = 902
        let expandedMainOnB = makeSnapshot(
            main: displayB,
            displays: [
                makeDisplayInfo(id: displayA, serial: 1, managed: true),
                makeDisplayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )

        let harness = makeHarness(
            configs: [makeConfig(serial: 1, desiredEnabled: true), makeConfig(serial: 2, desiredEnabled: true)],
            snapshots: Array(repeating: expandedMainOnB, count: 120),
            repairerShouldSucceed: true
        )

        try await harness.coordinator.ensureHealthyTopologyAfterEnable(
            preferredMainDisplayID: displayA,
            recoveryMode: .aggressive
        )

        #expect(harness.repairer.callCount >= 1)
        #expect(harness.repairer.lastAnchorDisplayID == displayA)
    }

    @Test
    func ensureHealthyTopologyThrowsRepairFailedWhenRepairerReturnsFalse() async {
        let displayA: CGDirectDisplayID = 301
        let displayB: CGDirectDisplayID = 302
        let collapsed = makeSnapshot(
            main: displayB,
            displays: [
                makeDisplayInfo(id: displayA, serial: 1, managed: true, inMirrorSet: true, mirrorMasterID: displayB),
                makeDisplayInfo(id: displayB, serial: 2, managed: true, inMirrorSet: true, mirrorMasterID: nil)
            ]
        )

        let harness = makeHarness(
            configs: [makeConfig(serial: 1, desiredEnabled: true), makeConfig(serial: 2, desiredEnabled: true)],
            snapshots: [collapsed, collapsed, collapsed],
            repairerShouldSucceed: false
        )

        do {
            try await harness.coordinator.ensureHealthyTopologyAfterEnable()
            Issue.record("Expected topologyRepairFailed")
        } catch let error as VirtualDisplayOperationError {
            guard case .topologyRepairFailed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func ensureHealthyTopologyThrowsUnstableWhenTopologyOscillates() async {
        let first = makeSnapshot(
            main: 601,
            displays: [makeDisplayInfo(id: 601, serial: 1, managed: true)]
        )
        let second = makeSnapshot(
            main: 602,
            displays: [makeDisplayInfo(id: 602, serial: 1, managed: true)]
        )

        let harness = makeHarness(
            configs: [makeConfig(serial: 1, desiredEnabled: true)],
            snapshots: [first, second],
            sequenceMode: .cycle,
            topologyStabilityTimeout: 0.05,
            topologyStabilityPollInterval: 0.001
        )

        do {
            try await harness.coordinator.ensureHealthyTopologyAfterEnable()
            Issue.record("Expected topologyUnstableAfterEnable")
        } catch let error as VirtualDisplayOperationError {
            guard case .topologyUnstableAfterEnable = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

private extension DisplayRebuildCoordinatorTests {
    struct Harness {
        let coordinator: DisplayRebuildCoordinator
        let runtimeTracker: VirtualDisplayRuntimeTracker
        let repairer: FakeDisplayTopologyRepairer
    }

    @MainActor
    func makeHarness(
        configs: [VirtualDisplayConfig],
        snapshots: [DisplayTopologySnapshot],
        sequenceMode: FakeSnapshotProvider.SequenceMode = .repeatLast,
        repairerShouldSucceed: Bool = true,
        topologyStabilityTimeout: TimeInterval = 0.2,
        topologyStabilityPollInterval: TimeInterval = 0.001,
        hook: (@MainActor (VirtualDisplayConfig, Bool, VirtualDisplayRuntimeTracker) async throws -> Void)? = nil
    ) -> Harness {
        let store = FakeVirtualDisplayStore()
        let repository = VirtualDisplayConfigRepository(store: store, reportFailure: nil)
        let configManager = VirtualDisplayConfigManager(
            configRepository: repository,
            activeSerialNumbersProvider: { [] }
        )
        store.nextLoadConfigs = configs
        configManager.loadPersistedConfigs()
        store.nextLoadConfigs = []
        let clock = TestVirtualDisplayClock()

        let teardownCoordinator = DisplayTeardownCoordinator(
            managedDisplayOnlineChecker: { _ in false },
            isReconfigurationMonitorAvailable: false,
            clock: clock
        )
        let runtimeTracker = VirtualDisplayRuntimeTracker(
            teardownCoordinator: teardownCoordinator,
            clock: clock
        )
        let policyResolver = MainDisplayPolicyResolver(
            enabledDesiredConfigsProvider: { configManager.enabledDesiredConfigs() },
            runtimeDisplayIDProvider: { configId in runtimeTracker.runtimeDisplayID(for: configId) },
            allConfigsProvider: { configManager.allConfigs() }
        )

        let snapshotProvider = FakeSnapshotProvider(snapshots: snapshots, sequenceMode: sequenceMode)
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: repairerShouldSucceed)

        let coordinator = DisplayRebuildCoordinator(
            dependencies: .init(
                configManager: configManager,
                runtimeTracker: runtimeTracker,
                teardownCoordinator: teardownCoordinator,
                policyResolver: policyResolver,
                topologyRepairer: repairer,
                clock: clock,
                topologyStabilityTimeout: topologyStabilityTimeout,
                topologyStabilityPollInterval: topologyStabilityPollInterval,
                rebuildRuntimeDisplayHook: { config, terminationConfirmed in
                    try await hook?(config, terminationConfirmed, runtimeTracker)
                },
                currentTopologySnapshot: {
                    snapshotProvider.next()
                },
                waitForAdaptiveManagedDisplayCooldown: { _, _ in
                    VirtualDisplayAdaptiveCooldownResult(waitedSeconds: 0, completedEarly: true)
                },
                logTopologySnapshot: { _, _ in }
            )
        )

        return Harness(
            coordinator: coordinator,
            runtimeTracker: runtimeTracker,
            repairer: repairer
        )
    }

    func makeConfig(serial: UInt32, desiredEnabled: Bool) -> VirtualDisplayConfig {
        VirtualDisplayConfig(
            id: UUID(),
            displayName: "Managed \(serial)",
            serialNum: serial,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: desiredEnabled
        )
    }

    func makeSnapshot(
        main: CGDirectDisplayID,
        displays: [DisplayTopologySnapshot.DisplayInfo]
    ) -> DisplayTopologySnapshot {
        DisplayTopologySnapshot(
            mainDisplayID: main,
            displays: displays.sorted { $0.id < $1.id }
        )
    }

    func makeDisplayInfo(
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
            isActive: true,
            isInMirrorSet: inMirrorSet,
            mirrorMasterDisplayID: mirrorMasterID,
            bounds: bounds
        )
    }
}

private final class FakeSnapshotProvider {
    enum SequenceMode {
        case repeatLast
        case cycle
    }

    private let snapshots: [DisplayTopologySnapshot]
    private let sequenceMode: SequenceMode
    private var index = 0

    init(snapshots: [DisplayTopologySnapshot], sequenceMode: SequenceMode) {
        self.snapshots = snapshots
        self.sequenceMode = sequenceMode
    }

    func next() -> DisplayTopologySnapshot? {
        guard !snapshots.isEmpty else { return nil }
        let resolvedIndex: Int
        switch sequenceMode {
        case .repeatLast:
            resolvedIndex = min(index, snapshots.count - 1)
        case .cycle:
            resolvedIndex = index % snapshots.count
        }
        index += 1
        return snapshots[resolvedIndex]
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
