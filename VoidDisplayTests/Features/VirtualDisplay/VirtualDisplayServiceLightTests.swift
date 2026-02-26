import CoreGraphics
import Foundation
import Testing
@testable import VoidDisplay

@MainActor
@Suite(.serialized)
struct VirtualDisplayServiceLightTests {
    @Test
    func moveConfigReordersAndPersists() {
        let store = FakeVirtualDisplayStore()
        let sut = makeService(store: store)

        let configA = makeConfig(serial: 1, displayName: "A")
        let configB = makeConfig(serial: 2, displayName: "B")
        sut.replaceDisplayConfigs([configA, configB])

        let moved = sut.moveConfig(configB.id, direction: .up)

        #expect(moved)
        #expect(sut.currentDisplayConfigs.first?.id == configB.id)
        #expect(store.saves.count == 1)
        #expect(store.saves.last?.first?.id == configB.id)
    }

    @Test
    func moveConfigOutOfBoundsDoesNotPersist() {
        let store = FakeVirtualDisplayStore()
        let sut = makeService(store: store)

        let configA = makeConfig(serial: 1, displayName: "A")
        let configB = makeConfig(serial: 2, displayName: "B")
        sut.replaceDisplayConfigs([configA, configB])

        let moved = sut.moveConfig(configA.id, direction: .up)

        #expect(moved == false)
        #expect(store.saves.isEmpty)
    }

    @Test
    func moveConfigToFirstEnabledPositionMovesEnabledTargetToFirstEnabledSlot() {
        let store = FakeVirtualDisplayStore()
        let sut = makeService(store: store)

        var disabledA = makeConfig(serial: 11, displayName: "Disabled A")
        var disabledB = makeConfig(serial: 12, displayName: "Disabled B")
        let enabledC = makeConfig(serial: 13, displayName: "Enabled C")
        let enabledD = makeConfig(serial: 14, displayName: "Enabled D")
        disabledA.desiredEnabled = false
        disabledB.desiredEnabled = false
        sut.replaceDisplayConfigs([disabledA, disabledB, enabledC, enabledD])

        let moved = sut.moveConfigToFirstEnabledPosition(enabledD.id)

        #expect(moved)
        #expect(sut.currentDisplayConfigs.map(\.id) == [disabledA.id, disabledB.id, enabledD.id, enabledC.id])
        #expect(store.saves.count == 1)
    }

    @Test
    func moveConfigToFirstEnabledPositionNoOpWhenTargetAlreadyFirstEnabled() {
        let store = FakeVirtualDisplayStore()
        let sut = makeService(store: store)

        let enabledA = makeConfig(serial: 21, displayName: "A")
        let enabledB = makeConfig(serial: 22, displayName: "B")
        sut.replaceDisplayConfigs([enabledA, enabledB])

        let moved = sut.moveConfigToFirstEnabledPosition(enabledA.id)

        #expect(moved == false)
        #expect(store.saves.isEmpty)
    }

    @Test
    func moveConfigToFirstEnabledPositionRejectsDisabledTarget() {
        let store = FakeVirtualDisplayStore()
        let sut = makeService(store: store)

        var disabledA = makeConfig(serial: 31, displayName: "A")
        let enabledB = makeConfig(serial: 32, displayName: "B")
        disabledA.desiredEnabled = false
        sut.replaceDisplayConfigs([disabledA, enabledB])

        let moved = sut.moveConfigToFirstEnabledPosition(disabledA.id)

        #expect(moved == false)
        #expect(sut.currentDisplayConfigs.map(\.id) == [disabledA.id, enabledB.id])
        #expect(store.saves.isEmpty)
    }

    @Test
    func moveConfigToFirstEnabledPositionNoOpWhenNoEnabledConfigsExist() {
        let store = FakeVirtualDisplayStore()
        let sut = makeService(store: store)

        var configA = makeConfig(serial: 41, displayName: "A")
        var configB = makeConfig(serial: 42, displayName: "B")
        configA.desiredEnabled = false
        configB.desiredEnabled = false
        sut.replaceDisplayConfigs([configA, configB])

        let moved = sut.moveConfigToFirstEnabledPosition(configB.id)

        #expect(moved == false)
        #expect(store.saves.isEmpty)
    }

    @Test
    func updateConfigPersistsReplacement() {
        let store = FakeVirtualDisplayStore()
        let sut = makeService(store: store)
        let config = makeConfig(serial: 9, displayName: "Old")
        sut.replaceDisplayConfigs([config])

        var updated = config
        updated.displayName = "New"
        sut.updateConfig(updated)

        #expect(sut.currentDisplayConfigs.first?.displayName == "New")
        #expect(store.saves.count == 1)
        #expect(store.saves.last?.first?.displayName == "New")
    }

    @Test
    func seedRuntimeBookkeepingMarksRunning() {
        let sut = makeService(store: FakeVirtualDisplayStore())
        let config = makeConfig(serial: 3, displayName: "Test")
        sut.replaceDisplayConfigs([config])

        sut.seedRuntimeBookkeeping(
            configId: config.id,
            generation: 5,
            runtimeDisplayID: 123
        )

        let state = sut.runtimeBookkeeping(configId: config.id)
        #expect(state.isRunning)
        #expect(state.generation == 5)
    }

    @Test
    func rollbackEnableKeepsGenerationButClearsRunning() {
        let sut = makeService(store: FakeVirtualDisplayStore())
        let config = makeConfig(serial: 4, displayName: "Rollback")
        sut.replaceDisplayConfigs([config])
        sut.seedRuntimeBookkeeping(
            configId: config.id,
            generation: 9,
            runtimeDisplayID: 555
        )

        sut.rollbackEnableRuntimeState(configId: config.id, serialNum: config.serialNum)

        let state = sut.runtimeBookkeeping(configId: config.id)
        #expect(state.isRunning == false)
        #expect(state.generation == 9)
    }

    @Test
    func adaptiveCooldownExitsEarlyWhenTargetsDisappear() async {
        let present = DisplayTopologySnapshot(
            mainDisplayID: 10,
            displays: [
                .init(
                    id: 10,
                    serialNumber: 1,
                    isManagedVirtualDisplay: true,
                    isActive: true,
                    isInMirrorSet: false,
                    mirrorMasterDisplayID: nil,
                    bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
                )
            ]
        )
        let absent = DisplayTopologySnapshot(
            mainDisplayID: 10,
            displays: [
                .init(
                    id: 10,
                    serialNumber: 999,
                    isManagedVirtualDisplay: false,
                    isActive: true,
                    isInMirrorSet: false,
                    mirrorMasterDisplayID: nil,
                    bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
                )
            ]
        )
        let inspector = SequenceDisplayTopologyInspector(snapshots: [present, absent, absent])
        let sut = makeService(store: FakeVirtualDisplayStore(), inspector: inspector)

        let result = await sut.waitForAdaptiveManagedDisplayCooldown(
            serialNumbers: [1],
            maxCooldown: 2.0
        )

        #expect(result.completedEarly)
        #expect(result.waitedSeconds < 2.0)
    }

    @Test
    func disableByConfigMarksAggressiveWhenRuntimeMain() async {
        let store = FakeVirtualDisplayStore()
        let sut = makeService(store: store)
        let config = makeConfig(serial: 11, displayName: "Main")
        sut.replaceDisplayConfigs([config])

        // Pretend the runtime display was the system main display.
        sut.seedRuntimeBookkeeping(configId: config.id, generation: 42, runtimeDisplayID: CGMainDisplayID())

        try? await sut.disableDisplayByConfig(config.id)

        #expect(store.saves.count == 1)
        #expect(sut.currentDisplayConfigs.first?.desiredEnabled == false)
        #expect(sut.runtimeBookkeeping(configId: config.id).generation == 42)
        #expect(sut.runtimeDisplayID(for: config.id) == nil)
        #expect(sut.aggressiveRecoveryPendingEnableConfigIDs.contains(config.id))
        #expect(sut.runningConfigIds.contains(config.id) == false)
    }

    @Test
    func disableRuntimeDisplayWithoutMatchingPersistedConfigDoesNotPersistSyntheticConfig() {
        let store = FakeVirtualDisplayStore()
        let sut = makeService(store: store)
        let existing = makeConfig(serial: 21, displayName: "用户配置 21")
        sut.replaceDisplayConfigs([existing])

        sut.disableRuntimeDisplay(
            serialNum: 99,
            displayID: 9_999,
            modes: []
        )

        #expect(store.saves.isEmpty)
        #expect(sut.currentDisplayConfigs.count == 1)
        #expect(sut.currentDisplayConfigs.first?.serialNum == existing.serialNum)
        #expect(sut.currentDisplayConfigs.first?.displayName == existing.displayName)
        #expect(sut.currentDisplayConfigs.contains(where: { $0.serialNum == 99 }) == false)
    }

    @Test
    func runtimeDisablePathPreservesDisplayNameWhenPersistingDesiredEnabledChange() {
        let store = FakeVirtualDisplayStore()
        let sut = makeService(store: store)
        let config = makeConfig(serial: 25, displayName: "用户配置 25")
        sut.replaceDisplayConfigs([config])

        sut.disableRuntimeDisplay(
            serialNum: config.serialNum,
            displayID: 2_500,
            modes: []
        )

        #expect(store.saves.count == 1)
        #expect(store.saves.last?.first?.displayName == "用户配置 25")
        #expect(sut.currentDisplayConfigs.first?.desiredEnabled == false)
        #expect(sut.currentDisplayConfigs.first?.displayName == "用户配置 25")
    }

    @Test
    func resolveMainDisplayPolicyUsesFirstEnabledConfigInPureVirtualMultiDisplay() {
        let sut = makeService(store: FakeVirtualDisplayStore())
        let configA = makeConfig(serial: 31, displayName: "A")
        let configB = makeConfig(serial: 32, displayName: "B")
        sut.replaceDisplayConfigs([configA, configB])
        sut.seedRuntimeBookkeeping(configId: configA.id, generation: 1, runtimeDisplayID: 501)
        sut.seedRuntimeBookkeeping(configId: configB.id, generation: 2, runtimeDisplayID: 502)

        let snapshot = DisplayTopologySnapshot(
            mainDisplayID: 502,
            displays: [
                makeDisplayInfo(id: 501, serial: 31, managed: true),
                makeDisplayInfo(id: 502, serial: 32, managed: true, bounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
            ]
        )

        let resolution = sut.resolveMainDisplayPolicy(snapshot: snapshot, emitLog: false)

        #expect(resolution.applies)
        #expect(resolution.source == .listOrder)
        #expect(resolution.targetConfigID == configA.id)
        #expect(resolution.targetDisplayID == 501)
        #expect(resolution.preferredMainDisplayID == 501)
    }

    @Test
    func resolveMainDisplayPolicySkipsDisabledFirstConfigAndSelectsNextEnabled() {
        let sut = makeService(store: FakeVirtualDisplayStore())
        var configA = makeConfig(serial: 41, displayName: "A")
        let configB = makeConfig(serial: 42, displayName: "B")
        let configC = makeConfig(serial: 43, displayName: "C")
        configA.desiredEnabled = false
        sut.replaceDisplayConfigs([configA, configB, configC])
        sut.seedRuntimeBookkeeping(configId: configB.id, generation: 1, runtimeDisplayID: 602)
        sut.seedRuntimeBookkeeping(configId: configC.id, generation: 2, runtimeDisplayID: 603)

        let snapshot = DisplayTopologySnapshot(
            mainDisplayID: 602,
            displays: [
                makeDisplayInfo(id: 602, serial: 42, managed: true),
                makeDisplayInfo(id: 603, serial: 43, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1440, height: 900))
            ]
        )

        let resolution = sut.resolveMainDisplayPolicy(snapshot: snapshot, emitLog: false)

        #expect(resolution.applies)
        #expect(resolution.source == .listOrder)
        #expect(resolution.targetConfigID == configB.id)
        #expect(resolution.targetDisplayID == 602)
    }

    @Test
    func resolveMainDisplayPolicyUsesRuntimeHintWhenTargetRuntimeObjectIsUnavailable() {
        let sut = makeService(store: FakeVirtualDisplayStore())
        let configA = makeConfig(serial: 51, displayName: "A")
        let configB = makeConfig(serial: 52, displayName: "B")
        sut.replaceDisplayConfigs([configA, configB])
        sut.runtimeDisplayIDHintsByConfigId[configA.id] = 701
        sut.runtimeDisplayIDHintsByConfigId[configB.id] = 702

        let snapshot = DisplayTopologySnapshot(
            mainDisplayID: 702,
            displays: [
                makeDisplayInfo(id: 701, serial: 51, managed: true),
                makeDisplayInfo(id: 702, serial: 52, managed: true, bounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
            ]
        )

        let resolution = sut.resolveMainDisplayPolicy(snapshot: snapshot, emitLog: false)

        #expect(resolution.applies)
        #expect(resolution.targetConfigID == configA.id)
        #expect(resolution.targetDisplayID == 701)
    }

    @Test
    func resolveMainDisplayPolicyLeavesTargetWithoutDisplayIDDuringTransition() {
        let sut = makeService(store: FakeVirtualDisplayStore())
        let configA = makeConfig(serial: 61, displayName: "A")
        let configB = makeConfig(serial: 62, displayName: "B")
        sut.replaceDisplayConfigs([configA, configB])

        let snapshot = DisplayTopologySnapshot(
            mainDisplayID: 800,
            displays: [
                makeDisplayInfo(id: 800, serial: 999, managed: false),
                makeDisplayInfo(id: 801, serial: 61, managed: true),
                makeDisplayInfo(id: 802, serial: 62, managed: true, bounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
            ]
        )
        let resolutionWithPhysical = sut.resolveMainDisplayPolicy(snapshot: snapshot, emitLog: false)
        #expect(resolutionWithPhysical.applies == false)
        #expect(resolutionWithPhysical.source == .policyDisabledPhysicalPresent)

        let pureVirtualSnapshot = DisplayTopologySnapshot(
            mainDisplayID: 801,
            displays: [
                makeDisplayInfo(id: 801, serial: 61, managed: true),
                makeDisplayInfo(id: 802, serial: 62, managed: true, bounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
            ]
        )
        let transitionResolution = sut.resolveMainDisplayPolicy(snapshot: pureVirtualSnapshot, emitLog: false)
        #expect(transitionResolution.applies)
        #expect(transitionResolution.targetConfigID == configA.id)
        #expect(transitionResolution.targetDisplayID == nil)
    }

    @Test
    func destroyDisplayClearsTrackingAndPersists() {
        let store = FakeVirtualDisplayStore()
        let sut = makeService(store: store)
        let config = makeConfig(serial: 12, displayName: "Destroy")
        sut.replaceDisplayConfigs([config])
        sut.seedRuntimeBookkeeping(configId: config.id, generation: 5, runtimeDisplayID: 777)
        sut.aggressiveRecoveryPendingEnableConfigIDs.insert(config.id)

        sut.destroyDisplay(config.id)

        #expect(store.saves.count == 1)
        #expect(sut.currentDisplayConfigs.isEmpty)
        #expect(sut.runtimeDisplayID(for: config.id) == nil)
        #expect(sut.runtimeBookkeeping(configId: config.id).isRunning == false)
        #expect(sut.aggressiveRecoveryPendingEnableConfigIDs.contains(config.id) == false)
    }

    @Test
    func resetAllVirtualDisplayDataClearsStateAndResetsStore() {
        let store = FakeVirtualDisplayStore()
        let sut = makeService(store: store)
        let configs = [makeConfig(serial: 1, displayName: "A"), makeConfig(serial: 2, displayName: "B")]
        sut.replaceDisplayConfigs(configs)
        sut.seedRuntimeBookkeeping(configId: configs[0].id, generation: 3, runtimeDisplayID: 101)
        sut.seedRuntimeBookkeeping(configId: configs[1].id, generation: 4, runtimeDisplayID: 202)

        let removed = sut.resetAllVirtualDisplayData()

        #expect(removed == 2)
        #expect(sut.currentDisplayConfigs.isEmpty)
        #expect(sut.runtimeDisplayID(for: configs[0].id) == nil)
        #expect(sut.runtimeBookkeeping(configId: configs[1].id).generation == nil)
        #expect(sut.runningConfigIds.isEmpty)
        #expect(store.resets == 1)
        #expect(store.saves.isEmpty)
    }

    @Test
    func loadPersistedConfigsFailureSetsStoreStateAndBlocksRestore() {
        let store = FakeVirtualDisplayStore()
        store.loadError = VirtualDisplayConfigStoreError.unsupportedSchemaVersion(expected: 3, actual: 2)
        let sut = makeService(store: store)

        sut.loadPersistedConfigs()
        sut.restoreDesiredVirtualDisplays()

        #expect(sut.currentDisplayConfigs.isEmpty)
        #expect(sut.currentRestoreFailures.isEmpty)
        switch sut.configStoreState {
        case .ready:
            Issue.record("Expected loadFailed config store state")
        case .loadFailed(let error, let diagnostics):
            if case .unsupportedSchemaVersion(let expected, let actual) = error {
                #expect(expected == 3)
                #expect(actual == 2)
            } else {
                Issue.record("Expected unsupportedSchemaVersion error")
            }
            #expect(diagnostics.primaryStoreURL.path == store.diagnosticsValue.primaryStoreURL.path)
        }
    }

    @Test
    func persistIsBlockedWhenConfigStoreStateIsLoadFailed() {
        let store = FakeVirtualDisplayStore()
        store.loadError = VirtualDisplayConfigStoreError.unsupportedSchemaVersion(expected: 3, actual: 2)
        let sut = makeService(store: store)
        let config = makeConfig(serial: 88, displayName: "Blocked")

        sut.loadPersistedConfigs()
        sut.replaceDisplayConfigs([config])

        var updated = config
        updated.displayName = "Blocked Rename"
        sut.updateConfig(updated)

        #expect(store.saves.isEmpty)
        #expect(sut.currentDisplayConfigs.first?.displayName == "Blocked Rename")
        switch sut.configStoreState {
        case .loadFailed:
            break
        case .ready:
            Issue.record("Expected loadFailed config store state")
        }
    }

    @Test
    func nextAvailableSerialNumberSkipsExisting() {
        let sut = makeService(store: FakeVirtualDisplayStore())
        sut.replaceDisplayConfigs([
            makeConfig(serial: 1, displayName: "One"),
            makeConfig(serial: 3, displayName: "Three")
        ])

        let next = sut.nextAvailableSerialNumber()

        #expect(next == 2)
    }
}

// MARK: - Helpers

private extension VirtualDisplayServiceLightTests {
    func makeService(
        store: FakeVirtualDisplayStore,
        inspector: any DisplayTopologyInspecting = DummyDisplayTopologyInspector()
    ) -> VirtualDisplayService {
        let repository = VirtualDisplayConfigRepository(store: store, reportFailure: nil)
        return VirtualDisplayService(
            configRepository: repository,
            displayReconfigurationMonitor: DummyDisplayReconfigurationMonitor(),
            topologyInspector: inspector,
            topologyRepairer: DummyDisplayTopologyRepairer(),
            managedDisplayOnlineChecker: { _ in false },
            topologyStabilityTimeout: 0.1,
            topologyStabilityPollInterval: 0.01,
            rebuildRuntimeDisplayHook: nil
        )
    }

    func makeConfig(serial: UInt32, displayName: String) -> VirtualDisplayConfig {
        VirtualDisplayConfig(
            id: UUID(),
            displayName: displayName,
            serialNum: serial,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [
                .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
            ],
            desiredEnabled: true
        )
    }

    func makeDisplayInfo(
        id: CGDirectDisplayID,
        serial: UInt32,
        managed: Bool,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900)
    ) -> DisplayTopologySnapshot.DisplayInfo {
        .init(
            id: id,
            serialNumber: serial,
            isManagedVirtualDisplay: managed,
            isActive: true,
            isInMirrorSet: false,
            mirrorMasterDisplayID: nil,
            bounds: bounds
        )
    }
}

@MainActor
private final class DummyDisplayReconfigurationMonitor: DisplayReconfigurationMonitoring {
    @discardableResult
    func start(handler: @escaping @MainActor () -> Void) -> Bool {
        // Do not schedule callbacks in these lightweight tests.
        handler()
        return true
    }

    func stop() {}
}

private final class DummyDisplayTopologyInspector: DisplayTopologyInspecting {
    func snapshot(
        trackedManagedSerials: Set<UInt32>,
        managedVendorID: UInt32,
        managedProductID: UInt32
    ) -> DisplayTopologySnapshot? {
        nil
    }
}

private final class SequenceDisplayTopologyInspector: DisplayTopologyInspecting {
    private let snapshots: [DisplayTopologySnapshot]
    private var index = 0

    init(snapshots: [DisplayTopologySnapshot]) {
        self.snapshots = snapshots
    }

    func snapshot(
        trackedManagedSerials: Set<UInt32>,
        managedVendorID: UInt32,
        managedProductID: UInt32
    ) -> DisplayTopologySnapshot? {
        guard !snapshots.isEmpty else { return nil }
        defer { if index + 1 < snapshots.count { index += 1 } }
        return snapshots[index]
    }
}

private final class DummyDisplayTopologyRepairer: DisplayTopologyRepairing {
    func repair(
        snapshot: DisplayTopologySnapshot,
        managedDisplayIDs: [CGDirectDisplayID],
        anchorDisplayID: CGDirectDisplayID
    ) -> Bool {
        true
    }
}
