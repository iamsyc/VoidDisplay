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
        let configA = makeConfig(serial: 1, displayName: "A")
        let configB = makeConfig(serial: 2, displayName: "B")
        let sut = makeService(store: store, initialConfigs: [configA, configB])

        let moved = sut.moveConfig(configB.id, direction: .up)

        #expect(moved)
        #expect(sut.currentDisplayConfigs.map(\.id) == [configB.id, configA.id])
        #expect(store.saves.count == 1)
        #expect(store.saves.last?.first?.id == configB.id)
    }

    @Test
    func moveConfigOutOfBoundsDoesNotPersist() {
        let store = FakeVirtualDisplayStore()
        let configA = makeConfig(serial: 1, displayName: "A")
        let configB = makeConfig(serial: 2, displayName: "B")
        let sut = makeService(store: store, initialConfigs: [configA, configB])

        let moved = sut.moveConfig(configA.id, direction: .up)

        #expect(moved == false)
        #expect(store.saves.isEmpty)
    }

    @Test
    func moveConfigToFirstEnabledPositionMovesEnabledTargetToFirstEnabledSlot() {
        let store = FakeVirtualDisplayStore()
        var disabledA = makeConfig(serial: 11, displayName: "Disabled A")
        var disabledB = makeConfig(serial: 12, displayName: "Disabled B")
        let enabledC = makeConfig(serial: 13, displayName: "Enabled C")
        let enabledD = makeConfig(serial: 14, displayName: "Enabled D")
        disabledA.desiredEnabled = false
        disabledB.desiredEnabled = false
        let sut = makeService(store: store, initialConfigs: [disabledA, disabledB, enabledC, enabledD])

        let moved = sut.moveConfigToFirstEnabledPosition(enabledD.id)

        #expect(moved)
        #expect(sut.currentDisplayConfigs.map(\.id) == [disabledA.id, disabledB.id, enabledD.id, enabledC.id])
        #expect(store.saves.count == 1)
    }

    @Test
    func updateConfigPersistsReplacement() {
        let store = FakeVirtualDisplayStore()
        let config = makeConfig(serial: 9, displayName: "Old")
        let sut = makeService(store: store, initialConfigs: [config])

        var updated = config
        updated.displayName = "New"
        sut.updateConfig(updated)

        #expect(sut.currentDisplayConfigs.first?.displayName == "New")
        #expect(store.saves.count == 1)
        #expect(store.saves.last?.first?.displayName == "New")
    }

    @Test
    func disableDisplayByConfigPersistsDesiredDisabled() throws {
        let store = FakeVirtualDisplayStore()
        let config = makeConfig(serial: 25, displayName: "用户配置 25")
        let sut = makeService(store: store, initialConfigs: [config])

        try sut.disableDisplayByConfig(config.id)

        #expect(store.saves.count == 1)
        #expect(sut.currentDisplayConfigs.first?.desiredEnabled == false)
        #expect(sut.currentDisplayConfigs.first?.displayName == "用户配置 25")
    }

    @Test
    func enableDisplaySetsDesiredEnabledEvenWhenRuntimeCreationFails() async {
        let store = FakeVirtualDisplayStore()
        var config = makeConfig(serial: 31, displayName: "Enable")
        config.desiredEnabled = false
        let sut = makeService(store: store, initialConfigs: [config])

        do {
            try await sut.enableDisplay(config.id)
        } catch {
            // Best-effort test: in CI/without display privileges creation may fail.
        }

        #expect(sut.currentDisplayConfigs.first?.desiredEnabled == true)
        #expect(store.saves.isEmpty == false)
    }

    @Test
    func destroyDisplayClearsConfigAndPersists() {
        let store = FakeVirtualDisplayStore()
        let config = makeConfig(serial: 12, displayName: "Destroy")
        let sut = makeService(store: store, initialConfigs: [config])

        sut.destroyDisplay(config.id)

        #expect(store.saves.count == 1)
        #expect(sut.currentDisplayConfigs.isEmpty)
        #expect(sut.runtimeDisplayID(for: config.id) == nil)
    }

    @Test
    func resetAllVirtualDisplayDataClearsStateAndResetsStore() {
        let store = FakeVirtualDisplayStore()
        let configs = [makeConfig(serial: 1, displayName: "A"), makeConfig(serial: 2, displayName: "B")]
        let sut = makeService(store: store, initialConfigs: configs)

        let removed = sut.resetAllVirtualDisplayData()

        #expect(removed == 2)
        #expect(sut.currentDisplayConfigs.isEmpty)
        #expect(sut.currentRestoreFailures.isEmpty)
        #expect(store.resets == 1)
        #expect(store.saves.isEmpty)
    }

    @Test
    func loadPersistedConfigsFailureSetsStoreStateAndBlocksRestore() {
        let store = FakeVirtualDisplayStore()
        store.loadError = VirtualDisplayConfigStoreError.unsupportedSchemaVersion(expected: 3, actual: 2)
        let sut = makeService(store: store, loadOnInit: false)

        sut.loadPersistedConfigs()
        sut.restoreDesiredVirtualDisplays()

        #expect(sut.currentDisplayConfigs.isEmpty)
        #expect(sut.currentRestoreFailures.isEmpty)
        #expect(sut.configStorePresentation.hasLoadFailure)
        #expect(sut.configStorePresentation.loadErrorMessage != nil)
        #expect(
            sut.configStorePresentation.diagnosticsSummary ==
                store.diagnosticsValue.summary
        )
    }

    @Test
    func reconcileMainDisplayPolicyNoSnapshotIsNoOp() async throws {
        let sut = makeService(store: FakeVirtualDisplayStore())
        try await sut.reconcileMainDisplayPolicyIfNeeded()
    }

    @Test
    func nextAvailableSerialNumberSkipsExisting() {
        let configA = makeConfig(serial: 1, displayName: "One")
        let configB = makeConfig(serial: 3, displayName: "Three")
        let sut = makeService(store: FakeVirtualDisplayStore(), initialConfigs: [configA, configB])

        let next = sut.nextAvailableSerialNumber()

        #expect(next == 2)
    }
}

// MARK: - Helpers

private extension VirtualDisplayServiceLightTests {
    func makeService(
        store: FakeVirtualDisplayStore,
        initialConfigs: [VirtualDisplayConfig] = [],
        inspector: any DisplayTopologyInspecting = DummyDisplayTopologyInspector(),
        loadOnInit: Bool = true
    ) -> VirtualDisplayService {
        store.nextLoadConfigs = initialConfigs
        let repository = VirtualDisplayConfigRepository(store: store, reportFailure: nil)
        let service = VirtualDisplayService(
            configRepository: repository,
            displayReconfigurationMonitor: DummyDisplayReconfigurationMonitor(),
            topologyInspector: inspector,
            topologyRepairer: DummyDisplayTopologyRepairer(),
            managedDisplayOnlineChecker: { _ in false },
            topologyStabilityTimeout: 0.1,
            topologyStabilityPollInterval: 0.01,
            rebuildRuntimeDisplayHook: nil
        )
        if loadOnInit {
            service.loadPersistedConfigs()
        }
        return service
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

}

@MainActor
private final class DummyDisplayReconfigurationMonitor: DisplayReconfigurationMonitoring {
    @discardableResult
    func start(handler: @escaping @MainActor () -> Void) -> Bool {
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

private final class DummyDisplayTopologyRepairer: DisplayTopologyRepairing {
    func repair(
        snapshot: DisplayTopologySnapshot,
        managedDisplayIDs: [CGDirectDisplayID],
        anchorDisplayID: CGDirectDisplayID
    ) -> Bool {
        true
    }
}
