import CoreGraphics
import Foundation
import Testing
@testable import VoidDisplay

@MainActor
@Suite(.serialized)
struct VirtualDisplayConfigManagerTests {
    @Test
    func loadPersistedConfigsSuccessLoadsConfigs() {
        let store = FakeVirtualDisplayStore()
        let configA = makeConfig(serial: 1, name: "A")
        let configB = makeConfig(serial: 2, name: "B")
        store.nextLoadConfigs = [configA, configB]

        let manager = makeManager(store: store)
        manager.loadPersistedConfigs()

        #expect(manager.allConfigs().map(\.id) == [configA.id, configB.id])
        #expect(manager.configStorePresentation.hasLoadFailure == false)
    }

    @Test
    func loadPersistedConfigsFailureClearsConfigsAndRestoreFailures() {
        let store = FakeVirtualDisplayStore()
        store.loadError = VirtualDisplayConfigStoreError.unsupportedSchemaVersion(expected: 3, actual: 2)

        let manager = makeManager(store: store)
        manager.setRestoreFailures([
            .init(id: UUID(), name: "X", serialNum: 10, message: "fail")
        ])
        manager.loadPersistedConfigs()

        #expect(manager.allConfigs().isEmpty)
        #expect(manager.restoreFailureList().isEmpty)
        #expect(manager.configStorePresentation.hasLoadFailure)
    }

    @Test
    func appendUpdateAndRemovePersistConfigChanges() {
        let store = FakeVirtualDisplayStore()
        let manager = makeManager(store: store)
        let config = makeConfig(serial: 10, name: "Original")

        manager.appendConfig(config)

        var updated = config
        updated.displayName = "Updated"
        manager.updateConfig(updated)
        manager.removeConfig(config.id)

        #expect(store.saves.count == 3)
        #expect(manager.allConfigs().isEmpty)
    }

    @Test
    func moveConfigSwapsAndPersists() {
        let store = FakeVirtualDisplayStore()
        let manager = makeManager(store: store)
        let configA = makeConfig(serial: 21, name: "A")
        let configB = makeConfig(serial: 22, name: "B")

        load(manager: manager, store: store, configs: [configA, configB])
        let moved = manager.moveConfig(configB.id, direction: .up)

        #expect(moved)
        #expect(manager.allConfigs().map(\.id) == [configB.id, configA.id])
        #expect(store.saves.count == 1)
    }

    @Test
    func moveConfigToFirstEnabledPositionMovesWithinEnabledSegment() {
        let store = FakeVirtualDisplayStore()
        let manager = makeManager(store: store)
        var disabledA = makeConfig(serial: 31, name: "A")
        var disabledB = makeConfig(serial: 32, name: "B")
        let enabledC = makeConfig(serial: 33, name: "C")
        let enabledD = makeConfig(serial: 34, name: "D")
        disabledA.desiredEnabled = false
        disabledB.desiredEnabled = false

        load(manager: manager, store: store, configs: [disabledA, disabledB, enabledC, enabledD])
        let moved = manager.moveConfigToFirstEnabledPosition(enabledD.id)

        #expect(moved)
        #expect(manager.allConfigs().map(\.id) == [disabledA.id, disabledB.id, enabledD.id, enabledC.id])
        #expect(store.saves.count == 1)
    }

    @Test
    func markDesiredDisabledBySerialOnlyMutatesMatchingConfig() {
        let store = FakeVirtualDisplayStore()
        let manager = makeManager(store: store)
        let configA = makeConfig(serial: 41, name: "A")
        let configB = makeConfig(serial: 42, name: "B")
        load(manager: manager, store: store, configs: [configA, configB])

        let changed = manager.markDesiredDisabledBySerial(configA.serialNum)

        #expect(changed)
        #expect(manager.config(id: configA.id)?.desiredEnabled == false)
        #expect(manager.config(id: configB.id)?.desiredEnabled == true)
    }

    @Test
    func nextAvailableSerialNumberSkipsConfigAndActiveSerials() {
        let activeSerials: Set<UInt32> = [2, 4]
        let store = FakeVirtualDisplayStore()
        let manager = makeManager(
            store: store,
            activeSerialNumbersProvider: { activeSerials }
        )
        load(manager: manager, store: store, configs: [
            makeConfig(serial: 1, name: "One"),
            makeConfig(serial: 3, name: "Three")
        ])

        let next = manager.nextAvailableSerialNumber()

        #expect(next == 5)
    }

    @Test
    func resetAllClearsConfigsAndResetsStore() {
        let store = FakeVirtualDisplayStore()
        let manager = makeManager(store: store)
        load(manager: manager, store: store, configs: [makeConfig(serial: 50, name: "Reset")])
        manager.setRestoreFailures([
            .init(id: UUID(), name: "X", serialNum: 50, message: "failure")
        ])

        manager.resetAll()

        #expect(manager.allConfigs().isEmpty)
        #expect(manager.restoreFailureList().isEmpty)
        #expect(store.resetCallCount == 1)
    }
}

private extension VirtualDisplayConfigManagerTests {
    func makeManager(
        store: FakeVirtualDisplayStore,
        activeSerialNumbersProvider: @escaping () -> Set<UInt32> = { [] }
    ) -> VirtualDisplayConfigManager {
        let repository = VirtualDisplayConfigRepository(store: store, reportFailure: nil)
        return VirtualDisplayConfigManager(
            configRepository: repository,
            activeSerialNumbersProvider: activeSerialNumbersProvider
        )
    }

    func makeConfig(serial: UInt32, name: String) -> VirtualDisplayConfig {
        VirtualDisplayConfig(
            id: UUID(),
            displayName: name,
            serialNum: serial,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [
                .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
            ],
            desiredEnabled: true
        )
    }

    func load(
        manager: VirtualDisplayConfigManager,
        store: FakeVirtualDisplayStore,
        configs: [VirtualDisplayConfig]
    ) {
        store.nextLoadConfigs = configs
        manager.loadPersistedConfigs()
        store.nextLoadConfigs = []
    }
}
