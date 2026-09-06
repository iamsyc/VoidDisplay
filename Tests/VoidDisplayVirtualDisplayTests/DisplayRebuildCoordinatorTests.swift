@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayFoundation
@testable import VoidDisplayVirtualDisplayTestingSupport
import CoreGraphics
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRebuildCoordinatorTests {
    @Test(arguments: [UInt32(0), 1, 2, 3])
    func fleetRestoresPeersAfterCreationFailure(failedSerial: UInt32) async throws {
        let configs = (1...3).map { makeConfig(serial: UInt32($0), desiredEnabled: true) }
        let driver = FleetRuntimeDriver()
        driver.beforeCreate = { descriptor in
            if descriptor.serialNumber == failedSerial { throw VirtualDisplayOperationError.creationFailed }
        }
        let survivors = configs.filter { $0.serialNum != failedSerial }
        let snapshot = makeSnapshot(main: 2000 + survivors[0].serialNum, displays: survivors.enumerated().map { index, config in
            makeDisplayInfo(id: 2000 + config.serialNum, serial: config.serialNum, managed: true,
                            bounds: CGRect(x: index * 1920, y: 0, width: 1920, height: 1080))
        })
        let harness = makeHarness(configs: configs, snapshots: [snapshot], runtimeDriver: driver)
        for config in configs {
            harness.runtimeTracker.markConfigRunning(configId: config.id, generation: 1, runtimeDisplayID: 1000 + config.serialNum)
        }

        do {
            try await harness.coordinator.rebuildManagedDisplayFleet(
                prioritizing: configs[0].id, fallbackPreferredMainDisplayID: nil, teardownStrategy: .fleetOfflineOnly
            )
            #expect(failedSerial == 0)
        } catch let error as VirtualDisplayOperationError {
            #expect(failedSerial != 0)
            // The existing unconfirmed-termination retry policy reports exhausted creation as teardownTimedOut.
            guard case .teardownTimedOut = error else { Issue.record("Unexpected error: \(error)"); return }
        }
        #expect(harness.runtimeTracker.runningConfigIDs() == Set(survivors.map(\.id)))
        #expect(Set(driver.createdSerials) == Set(configs.map(\.serialNum)))
        if failedSerial != 0 {
            #expect(driver.createdSerials.filter { $0 == failedSerial }.count == 10)
        }
        #expect(harness.snapshotProvider.readCount > 1, "Topology must converge even after a creation failure")
    }

    @Test func fleetPropagatesFirstCreationErrorAfterAttemptingAllPeers() async {
        let configs = (1...3).map { makeConfig(serial: UInt32($0), desiredEnabled: true) }
        var attempted: [UUID] = []
        let harness = makeHarness(configs: configs, snapshots: []) { config, _, _ in
            attempted.append(config.id)
            throw NSError(domain: "FleetCreate", code: Int(config.serialNum))
        }
        for config in configs {
            harness.runtimeTracker.markConfigRunning(configId: config.id, generation: 1, runtimeDisplayID: 1000 + config.serialNum)
        }
        do {
            try await harness.coordinator.rebuildManagedDisplayFleet(
                prioritizing: configs[0].id, fallbackPreferredMainDisplayID: nil, teardownStrategy: .fleetOfflineOnly
            )
            Issue.record("Expected the first creation failure")
        } catch {
            #expect((error as NSError).domain == "FleetCreate")
            #expect((error as NSError).code == 1)
        }
        #expect(attempted == configs.map(\.id))
        #expect(harness.snapshotProvider.readCount > 1)
    }

    @Test(arguments: ["reset", "deleteCurrent", "deletePending"])
    func fleetDoesNotRecreateRemovedConfigurations(action: String) async throws {
        let configs = (1...3).map { makeConfig(serial: UInt32($0), desiredEnabled: true) }
        let driver = FleetRuntimeDriver()
        let snapshot = makeSnapshot(main: 2001, displays: [makeDisplayInfo(id: 2001, serial: 1, managed: true)])
        let harness = makeHarness(configs: configs, snapshots: [snapshot], runtimeDriver: driver)
        for config in configs {
            harness.runtimeTracker.markConfigRunning(configId: config.id, generation: 1, runtimeDisplayID: 1000 + config.serialNum)
        }
        driver.beforeCreate = { descriptor in
            guard descriptor.serialNumber == 1 else { return }
            switch action {
            case "reset":
                try harness.configManager.resetAll()
                harness.runtimeTracker.resetAll()
            case "deleteCurrent":
                try harness.configManager.removeConfig(configs[0].id)
            default:
                try harness.configManager.removeConfig(configs[1].id)
            }
        }
        do {
            try await harness.coordinator.rebuildManagedDisplayFleet(
                prioritizing: configs[0].id, fallbackPreferredMainDisplayID: nil, teardownStrategy: .fleetOfflineOnly
            )
            #expect(action == "deletePending")
        } catch {
            #expect(action != "deletePending")
            if !(error is CancellationError) {
                guard let operationError = error as? VirtualDisplayOperationError,
                      case .configNotFound = operationError else { Issue.record("Unexpected error: \(error)"); return }
            }
        }
        if action == "deletePending" {
            #expect(driver.createdSerials == [1, 3])
            #expect(!harness.runtimeTracker.isVirtualDisplayRunning(configId: configs[1].id))
        } else {
            #expect(driver.createdSerials == [1])
            #expect(harness.runtimeTracker.runningConfigIDs().isEmpty)
        }
    }

    @Test func fleetCancellationStopsPeerRestoration() async {
        let configs = (1...3).map { makeConfig(serial: UInt32($0), desiredEnabled: true) }
        let driver = FleetRuntimeDriver()
        var resumeCreation: CheckedContinuation<Void, Never>?
        driver.beforeCreate = { _ in
            await withCheckedContinuation { resumeCreation = $0 }
            try Task.checkCancellation()
        }
        let harness = makeHarness(configs: configs, snapshots: [], runtimeDriver: driver)
        for config in configs {
            harness.runtimeTracker.markConfigRunning(configId: config.id, generation: 1, runtimeDisplayID: 1000 + config.serialNum)
        }
        let task = Task {
            try await harness.coordinator.rebuildManagedDisplayFleet(
                prioritizing: configs[0].id, fallbackPreferredMainDisplayID: nil, teardownStrategy: .fleetOfflineOnly
            )
        }
        while resumeCreation == nil { await Task.yield() }
        task.cancel()
        resumeCreation?.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(driver.createdSerials == [1])
        #expect(harness.runtimeTracker.runningConfigIDs().isEmpty)
    }

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
    func rebuildManagedDisplayFleetIncludesPrioritizedConfigWhenRequestedEvenIfStopped() async throws {
        let mainID: CGDirectDisplayID = 1301
        let peerID: CGDirectDisplayID = 1302
        let configA = makeConfig(serial: 31, desiredEnabled: true)
        let configB = makeConfig(serial: 32, desiredEnabled: true)
        let stableSnapshot = makeSnapshot(
            main: mainID,
            displays: [
                makeDisplayInfo(id: mainID, serial: configA.serialNum, managed: true),
                makeDisplayInfo(
                    id: peerID,
                    serial: configB.serialNum,
                    managed: true,
                    bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
                )
            ]
        )

        var rebuiltOrder: [UUID] = []
        let harness = makeHarness(
            configs: [configA, configB],
            snapshots: Array(repeating: stableSnapshot, count: 120),
            hook: { config, _, runtimeTracker in
                rebuiltOrder.append(config.id)
                let runtimeID = config.id == configA.id ? mainID : peerID
                runtimeTracker.markConfigRunning(
                    configId: config.id,
                    generation: UInt64(300 + rebuiltOrder.count),
                    runtimeDisplayID: runtimeID
                )
            }
        )
        harness.runtimeTracker.markConfigRunning(configId: configB.id, generation: 22, runtimeDisplayID: peerID)

        try await harness.coordinator.rebuildManagedDisplayFleet(
            prioritizing: configA.id,
            fallbackPreferredMainDisplayID: mainID,
            includePrioritizedConfigIfNotRunning: true
        )

        #expect(rebuiltOrder == [configA.id, configB.id])
        #expect(Set(harness.runtimeTracker.runningConfigIDs()) == Set([configA.id, configB.id]))
    }

    @Test
    func rebuildManagedDisplayFleetFleetOfflineOnlyKeepsRebuildUnsettledTerminationFlagsFalse() async throws {
        let mainID: CGDirectDisplayID = 1401
        let peerID: CGDirectDisplayID = 1402
        let configA = makeConfig(serial: 41, desiredEnabled: true)
        let configB = makeConfig(serial: 42, desiredEnabled: true)
        let stableSnapshot = makeSnapshot(
            main: mainID,
            displays: [
                makeDisplayInfo(id: mainID, serial: configA.serialNum, managed: true),
                makeDisplayInfo(
                    id: peerID,
                    serial: configB.serialNum,
                    managed: true,
                    bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
                )
            ]
        )

        var terminationFlags: [Bool] = []
        let harness = makeHarness(
            configs: [configA, configB],
            snapshots: Array(repeating: stableSnapshot, count: 120),
            hook: { config, terminationConfirmed, runtimeTracker in
                terminationFlags.append(terminationConfirmed)
                let runtimeID = config.id == configA.id ? mainID : peerID
                runtimeTracker.markConfigRunning(
                    configId: config.id,
                    generation: UInt64(400 + terminationFlags.count),
                    runtimeDisplayID: runtimeID
                )
            }
        )
        harness.runtimeTracker.markConfigRunning(configId: configA.id, generation: 32, runtimeDisplayID: mainID)
        harness.runtimeTracker.markConfigRunning(configId: configB.id, generation: 33, runtimeDisplayID: peerID)

        try await harness.coordinator.rebuildManagedDisplayFleet(
            prioritizing: configA.id,
            fallbackPreferredMainDisplayID: peerID,
            teardownStrategy: .fleetOfflineOnly
        )

        #expect(terminationFlags == [false, false])
        #expect(Set(harness.runtimeTracker.runningConfigIDs()) == Set([configA.id, configB.id]))
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
        let configManager: VirtualDisplayConfigManager
        let snapshotProvider: FakeSnapshotProvider
    }

    @MainActor
    func makeHarness(
        configs: [VirtualDisplayConfig],
        snapshots: [DisplayTopologySnapshot],
        sequenceMode: FakeSnapshotProvider.SequenceMode = .repeatLast,
        repairerShouldSucceed: Bool = true,
        topologyStabilityTimeout: TimeInterval = 0.2,
        topologyStabilityPollInterval: TimeInterval = 0.001,
        runtimeDriver: (any VirtualDisplayRuntimeDriving)? = nil,
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
            runtimeDriver: runtimeDriver ?? NoopRuntimeDriver(),
            clock: clock
        )
        let policyResolver = MainDisplayPolicyResolver(
            enabledDesiredConfigsProvider: { configManager.enabledDesiredConfigs() },
            runtimeDisplayIDProvider: { configId in runtimeTracker.runtimeDisplayID(for: configId) },
            allConfigsProvider: { configManager.allConfigs() }
        )

        let snapshotProvider = FakeSnapshotProvider(snapshots: snapshots, sequenceMode: sequenceMode)
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: repairerShouldSucceed)
        let rebuildHook: (@MainActor (VirtualDisplayConfig, Bool) async throws -> Void)?
        if let hook {
            rebuildHook = { config, terminationConfirmed in
                try await hook(config, terminationConfirmed, runtimeTracker)
            }
        } else {
            rebuildHook = nil
        }

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
                rebuildRuntimeDisplayHook: rebuildHook,
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
            repairer: repairer,
            configManager: configManager,
            snapshotProvider: snapshotProvider
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
    private(set) var readCount = 0

    init(snapshots: [DisplayTopologySnapshot], sequenceMode: SequenceMode) {
        self.snapshots = snapshots
        self.sequenceMode = sequenceMode
    }

    func next() -> DisplayTopologySnapshot? {
        readCount += 1
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

@MainActor
private final class FleetRuntimeDriver: VirtualDisplayRuntimeDriving {
    var beforeCreate: ((VirtualDisplayRuntimeDescriptor) async throws -> Void)?
    private(set) var createdSerials: [UInt32] = []

    func createRuntimeDisplay(
        descriptor: VirtualDisplayRuntimeDescriptor,
        onTermination: @escaping @MainActor () -> Void
    ) async throws -> any VirtualDisplayRuntimeHandling {
        createdSerials.append(descriptor.serialNumber)
        try await beforeCreate?(descriptor)
        return FleetRuntimeHandle(serialNum: descriptor.serialNumber)
    }
}

@MainActor
private final class FleetRuntimeHandle: VirtualDisplayRuntimeHandling {
    let serialNum: UInt32
    var displayID: CGDirectDisplayID { 2000 + serialNum }
    init(serialNum: UInt32) { self.serialNum = serialNum }
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

private final class NoopRuntimeDriver: VirtualDisplayRuntimeDriving {
    func createRuntimeDisplay(
        descriptor: VirtualDisplayRuntimeDescriptor,
        onTermination: @escaping @MainActor () -> Void
    ) async throws -> any VirtualDisplayRuntimeHandling {
        throw VirtualDisplayOperationError.creationFailed
    }
}
