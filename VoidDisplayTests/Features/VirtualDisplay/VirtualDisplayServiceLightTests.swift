import CoreGraphics
import Foundation
import Testing
@testable import VoidDisplay

@MainActor
struct VirtualDisplayServiceLightTests {
    @Test
    func moveConfigReordersAndPersists() {
        let store = InMemoryStore()
        let sut = makeService(store: store)

        let configA = makeConfig(serial: 1, name: "A")
        let configB = makeConfig(serial: 2, name: "B")
        sut.replaceDisplayConfigs([configA, configB])

        let moved = sut.moveConfig(configB.id, direction: .up)

        #expect(moved)
        #expect(sut.currentDisplayConfigs.first?.id == configB.id)
        #expect(store.saves.count == 1)
        #expect(store.saves.last?.first?.id == configB.id)
    }

    @Test
    func moveConfigOutOfBoundsDoesNotPersist() {
        let store = InMemoryStore()
        let sut = makeService(store: store)

        let configA = makeConfig(serial: 1, name: "A")
        let configB = makeConfig(serial: 2, name: "B")
        sut.replaceDisplayConfigs([configA, configB])

        let moved = sut.moveConfig(configA.id, direction: .up)

        #expect(moved == false)
        #expect(store.saves.isEmpty)
    }

    @Test
    func updateConfigPersistsReplacement() {
        let store = InMemoryStore()
        let sut = makeService(store: store)
        let config = makeConfig(serial: 9, name: "Old")
        sut.replaceDisplayConfigs([config])

        var updated = config
        updated.name = "New"
        sut.updateConfig(updated)

        #expect(sut.currentDisplayConfigs.first?.name == "New")
        #expect(store.saves.count == 1)
        #expect(store.saves.last?.first?.name == "New")
    }

    @Test
    func seedRuntimeBookkeepingMarksRunning() {
        let sut = makeService(store: InMemoryStore())
        let config = makeConfig(serial: 3, name: "Test")
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
        let sut = makeService(store: InMemoryStore())
        let config = makeConfig(serial: 4, name: "Rollback")
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
        let sut = makeService(store: InMemoryStore(), inspector: inspector)

        let result = await sut.waitForAdaptiveManagedDisplayCooldown(
            serialNumbers: [1],
            maxCooldown: 0.5
        )

        #expect(result.completedEarly)
        #expect(result.waitedSeconds < 0.5)
    }

    @Test
    func disableByConfigMarksAggressiveWhenRuntimeMain() async {
        let store = InMemoryStore()
        let sut = makeService(store: store)
        let config = makeConfig(serial: 11, name: "Main")
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
    func destroyDisplayClearsTrackingAndPersists() {
        let store = InMemoryStore()
        let sut = makeService(store: store)
        let config = makeConfig(serial: 12, name: "Destroy")
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
        let store = InMemoryStore()
        let sut = makeService(store: store)
        let configs = [makeConfig(serial: 1, name: "A"), makeConfig(serial: 2, name: "B")]
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
    func nextAvailableSerialNumberSkipsExisting() {
        let sut = makeService(store: InMemoryStore())
        sut.replaceDisplayConfigs([
            makeConfig(serial: 1, name: "One"),
            makeConfig(serial: 3, name: "Three")
        ])

        let next = sut.nextAvailableSerialNumber()

        #expect(next == 2)
    }
}

// MARK: - Helpers

private extension VirtualDisplayServiceLightTests {
    func makeService(
        store: InMemoryStore,
        inspector: any DisplayTopologyInspecting = DummyDisplayTopologyInspector()
    ) -> VirtualDisplayService {
        let persistence = VirtualDisplayPersistenceService(store: store, reportFailure: nil)
        return VirtualDisplayService(
            persistenceService: persistence,
            displayReconfigurationMonitor: DummyDisplayReconfigurationMonitor(),
            topologyInspector: inspector,
            topologyRepairer: DummyDisplayTopologyRepairer(),
            managedDisplayOnlineChecker: { _ in false },
            topologyStabilityTimeout: 0.1,
            topologyStabilityPollInterval: 0.01,
            rebuildRuntimeDisplayHook: nil
        )
    }

    func makeConfig(serial: UInt32, name: String) -> VirtualDisplayConfig {
        VirtualDisplayConfig(
            id: UUID(),
            name: name,
            serialNum: serial,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [
                .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
            ],
            desiredEnabled: true
        )
    }
}

// MARK: - Test Doubles

private final class InMemoryStore: VirtualDisplayStoring {
    var saves: [[VirtualDisplayConfig]] = []
    var resets = 0

    func load() throws -> [VirtualDisplayConfig] {
        saves.last ?? []
    }

    func save(_ configs: [VirtualDisplayConfig]) throws {
        saves.append(configs)
    }

    func reset() throws {
        resets += 1
        saves.removeAll()
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
