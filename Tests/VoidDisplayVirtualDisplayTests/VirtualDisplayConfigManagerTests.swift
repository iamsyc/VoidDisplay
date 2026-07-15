@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayFoundation
import CoreGraphics
import Foundation
import Testing

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
    func loadPersistedConfigsIfNeededReusesHydratedConfigs() {
        let store = FakeVirtualDisplayStore()
        let configA = makeConfig(serial: 1, name: "A")
        let configB = makeConfig(serial: 2, name: "B")
        store.nextLoadConfigs = [configA, configB]

        let manager = makeManager(store: store)
        let first = manager.loadPersistedConfigsIfNeeded()
        store.nextLoadConfigs = []
        let second = manager.loadPersistedConfigsIfNeeded()

        #expect(first.configs.map(\.id) == [configA.id, configB.id])
        #expect(second.configs.map(\.id) == [configA.id, configB.id])
        #expect(manager.allConfigs().map(\.id) == [configA.id, configB.id])
        #expect(store.loadCallCount == 1)
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
    func appendUpdateAndRemovePersistConfigChanges() throws {
        let store = FakeVirtualDisplayStore()
        let manager = makeManager(store: store)
        let config = makeConfig(serial: 10, name: "Original")

        try manager.appendConfig(config)

        var updated = config
        updated.displayName = "Updated"
        try manager.updateConfig(updated)
        try manager.removeConfig(config.id)

        #expect(store.savedConfigs.count == 3)
        #expect(manager.allConfigs().isEmpty)
    }

    @Test
    func updateConfigMissingConfigThrowsConfigNotFound() {
        let store = FakeVirtualDisplayStore()
        let manager = makeManager(store: store)

        do {
            try manager.updateConfig(makeConfig(serial: 11, name: "Missing"))
            Issue.record("Expected configNotFound")
        } catch VirtualDisplayOperationError.configNotFound {
        } catch {
            Issue.record("Expected configNotFound, got \(error)")
        }
        #expect(store.savedConfigs.isEmpty)
    }

    @Test
    func moveConfigSwapsAndPersists() throws {
        let store = FakeVirtualDisplayStore()
        let manager = makeManager(store: store)
        let configA = makeConfig(serial: 21, name: "A")
        let configB = makeConfig(serial: 22, name: "B")

        load(manager: manager, store: store, configs: [configA, configB])
        let moved = try manager.moveConfig(configB.id, direction: .up)

        #expect(moved)
        #expect(manager.allConfigs().map(\.id) == [configB.id, configA.id])
        #expect(store.savedConfigs.count == 1)
    }

    @Test
    func moveConfigToFirstEnabledPositionMovesWithinEnabledSegment() throws {
        let store = FakeVirtualDisplayStore()
        let manager = makeManager(store: store)
        var disabledA = makeConfig(serial: 31, name: "A")
        var disabledB = makeConfig(serial: 32, name: "B")
        let enabledC = makeConfig(serial: 33, name: "C")
        let enabledD = makeConfig(serial: 34, name: "D")
        disabledA.desiredEnabled = false
        disabledB.desiredEnabled = false

        load(manager: manager, store: store, configs: [disabledA, disabledB, enabledC, enabledD])
        let moved = try manager.moveConfigToFirstEnabledPosition(enabledD.id)

        #expect(moved)
        #expect(manager.allConfigs().map(\.id) == [disabledA.id, disabledB.id, enabledD.id, enabledC.id])
        #expect(store.savedConfigs.count == 1)
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
    func setDesiredEnabledMissingConfigThrowsConfigNotFound() {
        let store = FakeVirtualDisplayStore()
        let manager = makeManager(store: store)

        do {
            try manager.setDesiredEnabled(
                UUID(),
                enabled: true,
                reason: .userToggledDesiredEnabled
            )
            Issue.record("Expected configNotFound")
        } catch VirtualDisplayOperationError.configNotFound {
        } catch {
            Issue.record("Expected configNotFound, got \(error)")
        }
        #expect(store.savedConfigs.isEmpty)
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
    func resetAllClearsConfigsAndResetsStore() throws {
        let store = FakeVirtualDisplayStore()
        let manager = makeManager(store: store)
        load(manager: manager, store: store, configs: [makeConfig(serial: 50, name: "Reset")])
        manager.setRestoreFailures([
            .init(id: UUID(), name: "X", serialNum: 50, message: "failure")
        ])

        try manager.resetAll()

        #expect(manager.allConfigs().isEmpty)
        #expect(manager.restoreFailureList().isEmpty)
        #expect(store.resetCallCount == 1)
    }

    @Test
    func appendConfigSaveFailureLeavesMemoryUnchanged() {
        let store = FakeVirtualDisplayStore()
        store.saveError = VirtualDisplayConfigStoreError.ioFailed(
            operation: "save",
            underlying: NSError(domain: "test", code: 1)
        )
        let manager = makeManager(store: store)

        #expect(throws: Error.self) {
            try manager.appendConfig(makeConfig(serial: 60, name: "Broken"))
        }
        #expect(manager.allConfigs().isEmpty)
        #expect(store.savedConfigs.isEmpty)
    }

    @Test
    func updateConfigSaveFailureLeavesMemoryUnchanged() {
        let store = FakeVirtualDisplayStore()
        let config = makeConfig(serial: 61, name: "Original")
        let manager = makeManager(store: store)
        load(manager: manager, store: store, configs: [config])

        var updated = config
        updated.displayName = "Updated"
        store.saveError = VirtualDisplayConfigStoreError.ioFailed(
            operation: "save",
            underlying: NSError(domain: "test", code: 2)
        )

        #expect(throws: Error.self) {
            try manager.updateConfig(updated)
        }
        #expect(manager.allConfigs().first?.displayName == "Original")
        #expect(store.savedConfigs.isEmpty)
    }

    @Test
    func removeConfigSaveFailureLeavesMemoryUnchanged() {
        let store = FakeVirtualDisplayStore()
        let config = makeConfig(serial: 62, name: "Keep")
        let manager = makeManager(store: store)
        load(manager: manager, store: store, configs: [config])
        store.saveError = VirtualDisplayConfigStoreError.ioFailed(
            operation: "save",
            underlying: NSError(domain: "test", code: 3)
        )

        #expect(throws: Error.self) {
            try manager.removeConfig(config.id)
        }
        #expect(manager.allConfigs().map(\.id) == [config.id])
        #expect(store.savedConfigs.isEmpty)
    }

    @Test
    func setDesiredEnabledSaveFailureLeavesMemoryUnchanged() {
        let store = FakeVirtualDisplayStore()
        var config = makeConfig(serial: 63, name: "Toggle")
        config.desiredEnabled = false
        let manager = makeManager(store: store)
        load(manager: manager, store: store, configs: [config])
        store.saveError = VirtualDisplayConfigStoreError.ioFailed(
            operation: "save",
            underlying: NSError(domain: "test", code: 4)
        )

        #expect(throws: Error.self) {
            try manager.setDesiredEnabled(
                config.id,
                enabled: true,
                reason: .userToggledDesiredEnabled
            )
        }
        #expect(manager.allConfigs().first?.desiredEnabled == false)
        #expect(store.savedConfigs.isEmpty)
    }

    @Test
    func moveConfigSaveFailureLeavesMemoryOrderUnchanged() {
        let store = FakeVirtualDisplayStore()
        let configA = makeConfig(serial: 64, name: "A")
        let configB = makeConfig(serial: 65, name: "B")
        let manager = makeManager(store: store)
        load(manager: manager, store: store, configs: [configA, configB])
        store.saveError = VirtualDisplayConfigStoreError.ioFailed(
            operation: "save",
            underlying: NSError(domain: "test", code: 5)
        )

        #expect(throws: Error.self) {
            _ = try manager.moveConfig(configB.id, direction: .up)
        }
        #expect(manager.allConfigs().map(\.id) == [configA.id, configB.id])
        #expect(store.savedConfigs.isEmpty)
    }

    @Test
    func moveConfigToFirstEnabledPositionSaveFailureLeavesMemoryOrderUnchanged() {
        let store = FakeVirtualDisplayStore()
        var disabled = makeConfig(serial: 66, name: "Disabled")
        let enabledA = makeConfig(serial: 67, name: "Enabled A")
        let enabledB = makeConfig(serial: 68, name: "Enabled B")
        disabled.desiredEnabled = false
        let manager = makeManager(store: store)
        load(manager: manager, store: store, configs: [disabled, enabledA, enabledB])
        store.saveError = VirtualDisplayConfigStoreError.ioFailed(
            operation: "save",
            underlying: NSError(domain: "test", code: 6)
        )

        #expect(throws: Error.self) {
            _ = try manager.moveConfigToFirstEnabledPosition(enabledB.id)
        }
        #expect(manager.allConfigs().map(\.id) == [disabled.id, enabledA.id, enabledB.id])
        #expect(store.savedConfigs.isEmpty)
    }

    @Test
    func resetAllFailureLeavesMemoryUnchanged() {
        let store = FakeVirtualDisplayStore()
        let config = makeConfig(serial: 69, name: "Reset")
        let manager = makeManager(store: store)
        load(manager: manager, store: store, configs: [config])
        manager.setRestoreFailures([
            .init(id: UUID(), name: "X", serialNum: 69, message: "failure")
        ])
        store.resetError = VirtualDisplayConfigStoreError.ioFailed(
            operation: "reset",
            underlying: NSError(domain: "test", code: 7)
        )

        #expect(throws: Error.self) {
            try manager.resetAll()
        }
        #expect(manager.allConfigs().map(\.id) == [config.id])
        #expect(manager.restoreFailureList().count == 1)
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
