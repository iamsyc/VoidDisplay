import CoreGraphics
import Foundation
import Testing
@testable import VoidDisplay

@MainActor
@Suite(.serialized)
struct VirtualDisplayOrchestratorLightTests {
    @Test
    func moveConfigReordersAndPersists() throws {
        let store = FakeVirtualDisplayStore()
        let configA = makeConfig(serial: 1, displayName: "A")
        let configB = makeConfig(serial: 2, displayName: "B")
        let sut = makeOrchestrator(store: store, initialConfigs: [configA, configB])

        let moved = try sut.moveConfig(configB.id, direction: .up)

        #expect(moved)
        #expect(sut.snapshot.configs.map(\.id) == [configB.id, configA.id])
        #expect(store.savedConfigs.count == 1)
        #expect(store.savedConfigs.last?.first?.id == configB.id)
    }

    @Test
    func moveConfigOutOfBoundsDoesNotPersist() throws {
        let store = FakeVirtualDisplayStore()
        let configA = makeConfig(serial: 1, displayName: "A")
        let configB = makeConfig(serial: 2, displayName: "B")
        let sut = makeOrchestrator(store: store, initialConfigs: [configA, configB])

        let moved = try sut.moveConfig(configA.id, direction: .up)

        #expect(moved == false)
        #expect(store.savedConfigs.isEmpty)
    }

    @Test
    func moveConfigToFirstEnabledPositionMovesEnabledTargetToFirstEnabledSlot() throws {
        let store = FakeVirtualDisplayStore()
        var disabledA = makeConfig(serial: 11, displayName: "Disabled A")
        var disabledB = makeConfig(serial: 12, displayName: "Disabled B")
        let enabledC = makeConfig(serial: 13, displayName: "Enabled C")
        let enabledD = makeConfig(serial: 14, displayName: "Enabled D")
        disabledA.desiredEnabled = false
        disabledB.desiredEnabled = false
        let sut = makeOrchestrator(store: store, initialConfigs: [disabledA, disabledB, enabledC, enabledD])

        let moved = try sut.moveConfigToFirstEnabledPosition(enabledD.id)

        #expect(moved)
        #expect(sut.snapshot.configs.map(\.id) == [disabledA.id, disabledB.id, enabledD.id, enabledC.id])
        #expect(store.savedConfigs.count == 1)
    }

    @Test
    func updateConfigPersistsReplacement() throws {
        let store = FakeVirtualDisplayStore()
        let config = makeConfig(serial: 9, displayName: "Old")
        let sut = makeOrchestrator(store: store, initialConfigs: [config])

        var updated = config
        updated.displayName = "New"
        try sut.updateConfig(updated)

        #expect(sut.snapshot.configs.first?.displayName == "New")
        #expect(store.savedConfigs.count == 1)
        #expect(store.savedConfigs.last?.first?.displayName == "New")
    }

    @Test
    func disableDisplayByConfigPersistsDesiredDisabled() throws {
        let store = FakeVirtualDisplayStore()
        let config = makeConfig(serial: 25, displayName: "用户配置 25")
        let sut = makeOrchestrator(store: store, initialConfigs: [config])

        try sut.disableDisplayByConfig(config.id)

        #expect(store.savedConfigs.count == 1)
        #expect(sut.snapshot.configs.first?.desiredEnabled == false)
        #expect(sut.snapshot.configs.first?.displayName == "用户配置 25")
    }

    @Test
    func enableDisplaySetsDesiredEnabledEvenWhenRuntimeCreationFails() async {
        let store = FakeVirtualDisplayStore()
        var config = makeConfig(serial: 31, displayName: "Enable")
        config.desiredEnabled = false
        let sut = makeOrchestrator(store: store, initialConfigs: [config])

        do {
            try await sut.enableDisplay(config.id)
        } catch {
            // Best-effort test: in CI/without display privileges creation may fail.
        }

        #expect(sut.snapshot.configs.first?.desiredEnabled == true)
        #expect(store.savedConfigs.isEmpty == false)
    }

    @Test
    func enableDisplayRequiresTrueOfflineConfirmationBeforeRecreate() async throws {
        let store = FakeVirtualDisplayStore()
        let driver = FakeOrchestratorRuntimeDriver(
            scriptedResults: [.success(serialNum: 41, displayID: 941)]
        )
        var config = makeConfig(serial: 41, displayName: "Needs Offline")
        config.desiredEnabled = false
        var displayOnline = false
        let sut = makeOrchestrator(
            store: store,
            initialConfigs: [config],
            inspector: StableTopologyInspector(
                snapshot: DisplayTopologySnapshot(
                    mainDisplayID: 941,
                    displays: [
                        DisplayTopologySnapshot.DisplayInfo(
                            id: 941,
                            serialNumber: 41,
                            isManagedVirtualDisplay: true,
                            isActive: true,
                            isInMirrorSet: false,
                            mirrorMasterDisplayID: nil,
                            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
                        )
                    ]
                )
            ),
            managedDisplayOnlineChecker: { _ in displayOnline },
            runtimeDriver: driver
        )

        try await sut.enableDisplay(config.id)
        #expect(driver.createCallCount == 1)

        displayOnline = true
        try sut.disableDisplayByConfig(config.id)

        do {
            try await sut.enableDisplay(config.id)
            Issue.record("Expected enable to fail when prior display remains online.")
        } catch let error as VirtualDisplayOperationError {
            guard case .teardownTimedOut = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(driver.createCallCount == 1)
    }

    @Test
    func createDisplayRuntimeFailureRollsBackConfigAndRethrowsCreateError() {
        let store = FakeVirtualDisplayStore()
        let driver = FakeOrchestratorRuntimeDriver(
            scriptedResults: [.failure(VirtualDisplayOperationError.creationFailed)]
        )
        let sut = makeOrchestrator(store: store, runtimeDriver: driver)

        do {
            _ = try sut.createDisplay(
                name: "Rollback OK",
                serialNum: 51,
                physicalSize: CGSize(width: 300, height: 200),
                maxPixels: (width: 1920, height: 1080),
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
            Issue.record("Expected creationFailed error.")
        } catch let error as VirtualDisplayOperationError {
            guard case .creationFailed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        #expect(store.savedConfigs.count == 2)
        #expect(store.savedConfigs.last?.isEmpty == true)
        #expect(sut.snapshot.configs.isEmpty)
        #expect(sut.snapshot.runningConfigIds.isEmpty)
    }

    @Test
    func createDisplayRollbackFailureRaisesPersistenceRecoveryError() {
        let store = FakeVirtualDisplayStore()
        store.scriptedSaveErrors = [
            nil,
            VirtualDisplayConfigStoreError.ioFailed(
                operation: "save",
                underlying: NSError(domain: "test", code: 88)
            )
        ]
        let driver = FakeOrchestratorRuntimeDriver(
            scriptedResults: [.failure(VirtualDisplayOperationError.creationFailed)]
        )
        let sut = makeOrchestrator(store: store, runtimeDriver: driver)

        do {
            _ = try sut.createDisplay(
                name: "Rollback Broken",
                serialNum: 52,
                physicalSize: CGSize(width: 300, height: 200),
                maxPixels: (width: 1920, height: 1080),
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
            Issue.record("Expected persistence recovery failure.")
        } catch let error as VirtualDisplayOperationError {
            guard case .persistenceRecoveryFailed(let message) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message.contains("rollback"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(store.savedConfigs.count == 1)
        #expect(sut.snapshot.configs.count == 1)
        #expect(sut.snapshot.runningConfigIds.isEmpty)
    }

    @Test
    func destroyDisplayClearsConfigAndPersists() throws {
        let store = FakeVirtualDisplayStore()
        let config = makeConfig(serial: 12, displayName: "Destroy")
        let sut = makeOrchestrator(store: store, initialConfigs: [config])

        try sut.destroyDisplay(config.id)

        #expect(store.savedConfigs.count == 1)
        #expect(sut.snapshot.configs.isEmpty)
        #expect(sut.snapshot.runtimeDisplayID(for: config.id) == nil)
    }

    @Test
    func destroyDisplaySaveFailurePreservesConfigAndRuntimeState() throws {
        let store = FakeVirtualDisplayStore()
        let driver = FakeOrchestratorRuntimeDriver(
            scriptedResults: [.success(serialNum: 53, displayID: 953)]
        )
        let sut = makeOrchestrator(store: store, runtimeDriver: driver)
        let createdConfigID = try sut.createDisplay(
            name: "Keep On Failure",
            serialNum: 53,
            physicalSize: CGSize(width: 300, height: 200),
            maxPixels: (width: 1920, height: 1080),
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
        )
        let runtimeDisplayIDBeforeFailure = sut.snapshot.runtimeDisplayID(for: createdConfigID)
        store.saveError = VirtualDisplayConfigStoreError.ioFailed(
            operation: "save",
            underlying: NSError(domain: "test", code: 89)
        )

        #expect(throws: Error.self) {
            try sut.destroyDisplay(createdConfigID)
        }
        #expect(sut.snapshot.configs.map(\.id) == [createdConfigID])
        #expect(sut.snapshot.runningConfigIds == [createdConfigID])
        #expect(sut.snapshot.runtimeDisplayID(for: createdConfigID) == runtimeDisplayIDBeforeFailure)
    }

    @Test
    func resetAllVirtualDisplayDataClearsStateAndResetsStore() throws {
        let store = FakeVirtualDisplayStore()
        let configs = [makeConfig(serial: 1, displayName: "A"), makeConfig(serial: 2, displayName: "B")]
        let sut = makeOrchestrator(store: store, initialConfigs: configs)

        let removed = try sut.resetAllVirtualDisplayData()

        #expect(removed == 2)
        #expect(sut.snapshot.configs.isEmpty)
        #expect(sut.snapshot.restoreFailures.isEmpty)
        #expect(store.resetCallCount == 1)
        #expect(store.savedConfigs.isEmpty)
    }

    @Test
    func resetAllVirtualDisplayDataResetFailurePreservesConfigAndRuntimeState() throws {
        let store = FakeVirtualDisplayStore()
        let restoreFailureConfig = makeConfig(serial: 54, displayName: "Restore Failure")
        let driver = FakeOrchestratorRuntimeDriver(
            scriptedResults: [
                .failure(VirtualDisplayOperationError.creationFailed),
                .success(serialNum: 55, displayID: 955)
            ]
        )
        let sut = makeOrchestrator(
            store: store,
            initialConfigs: [restoreFailureConfig],
            runtimeDriver: driver
        )
        sut.restoreDesiredVirtualDisplays()
        #expect(sut.snapshot.restoreFailures.count == 1)

        let createdConfigID = try sut.createDisplay(
            name: "Reset Failure",
            serialNum: 55,
            physicalSize: CGSize(width: 300, height: 200),
            maxPixels: (width: 1920, height: 1080),
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
        )
        let runtimeDisplayIDBeforeFailure = sut.snapshot.runtimeDisplayID(for: createdConfigID)
        store.resetError = VirtualDisplayConfigStoreError.ioFailed(
            operation: "reset",
            underlying: NSError(domain: "test", code: 90)
        )

        #expect(throws: Error.self) {
            _ = try sut.resetAllVirtualDisplayData()
        }
        #expect(sut.snapshot.configs.map(\.id) == [restoreFailureConfig.id, createdConfigID])
        #expect(sut.snapshot.runningConfigIds == [createdConfigID])
        #expect(sut.snapshot.runtimeDisplayID(for: createdConfigID) == runtimeDisplayIDBeforeFailure)
        #expect(sut.snapshot.restoreFailures.count == 1)
        #expect(sut.snapshot.restoreFailures.first?.id == restoreFailureConfig.id)
    }

    @Test
    func loadPersistedConfigsFailureSetsStoreStateAndBlocksRestore() {
        let store = FakeVirtualDisplayStore()
        store.loadError = VirtualDisplayConfigStoreError.unsupportedSchemaVersion(expected: 3, actual: 2)
        let sut = makeOrchestrator(store: store, loadOnInit: false)

        sut.loadPersistedConfigs()
        sut.restoreDesiredVirtualDisplays()

        #expect(sut.snapshot.configs.isEmpty)
        #expect(sut.snapshot.restoreFailures.isEmpty)
        #expect(sut.snapshot.configStorePresentation.hasLoadFailure)
        #expect(sut.snapshot.configStorePresentation.loadErrorMessage != nil)
        #expect(
            sut.snapshot.configStorePresentation.diagnosticsSummary ==
                store.diagnosticsValue.summary
        )
    }

    @Test
    func reconcileMainDisplayPolicyNoSnapshotIsNoOp() async throws {
        let sut = makeOrchestrator(store: FakeVirtualDisplayStore())
        try await sut.reconcileMainDisplayPolicyIfNeeded()
    }

    @Test
    func nextAvailableSerialNumberSkipsExisting() {
        let configA = makeConfig(serial: 1, displayName: "One")
        let configB = makeConfig(serial: 3, displayName: "Three")
        let sut = makeOrchestrator(store: FakeVirtualDisplayStore(), initialConfigs: [configA, configB])

        let next = sut.nextAvailableSerialNumber()

        #expect(next == 2)
    }
}

// MARK: - Helpers

private extension VirtualDisplayOrchestratorLightTests {
    func makeOrchestrator(
        store: FakeVirtualDisplayStore,
        initialConfigs: [VirtualDisplayConfig] = [],
        inspector: any DisplayTopologyInspecting = DummyDisplayTopologyInspector(),
        managedDisplayOnlineChecker: @escaping (UInt32) -> Bool = { _ in false },
        runtimeDriver: (any VirtualDisplayRuntimeDriving)? = nil,
        loadOnInit: Bool = true
    ) -> VirtualDisplayOrchestrator {
        store.nextLoadConfigs = initialConfigs
        let repository = VirtualDisplayConfigRepository(store: store, reportFailure: nil)
        let orchestrator = VirtualDisplayOrchestrator(
            configRepository: repository,
            displayReconfigurationMonitor: DummyDisplayReconfigurationMonitor(),
            topologyInspector: inspector,
            topologyRepairer: DummyDisplayTopologyRepairer(),
            managedDisplayOnlineChecker: managedDisplayOnlineChecker,
            topologyStabilityTimeout: 0.1,
            topologyStabilityPollInterval: 0.01,
            rebuildRuntimeDisplayHook: nil,
            runtimeDriver: runtimeDriver
        )
        if loadOnInit {
            orchestrator.loadPersistedConfigs()
        }
        return orchestrator
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

private final class StableTopologyInspector: DisplayTopologyInspecting {
    private let snapshotValue: DisplayTopologySnapshot

    init(snapshot: DisplayTopologySnapshot) {
        self.snapshotValue = snapshot
    }

    func snapshot(
        trackedManagedSerials: Set<UInt32>,
        managedVendorID: UInt32,
        managedProductID: UInt32
    ) -> DisplayTopologySnapshot? {
        _ = trackedManagedSerials
        _ = managedVendorID
        _ = managedProductID
        return snapshotValue
    }
}

@MainActor
private final class FakeOrchestratorRuntimeDriver: VirtualDisplayRuntimeDriving {
    enum CreateResult {
        case success(serialNum: UInt32, displayID: CGDirectDisplayID)
        case failure(Error)
    }

    private let scriptedResults: [CreateResult]
    private var nextIndex = 0

    private(set) var createCallCount = 0

    init(scriptedResults: [CreateResult]) {
        self.scriptedResults = scriptedResults
    }

    func createRuntimeDisplay(
        from config: VirtualDisplayConfig,
        maxPixels: (width: UInt32, height: UInt32)?,
        onTermination: @escaping @MainActor () -> Void
    ) throws -> any VirtualDisplayRuntimeHandling {
        _ = maxPixels
        _ = onTermination
        createCallCount += 1
        let result: CreateResult
        if scriptedResults.indices.contains(nextIndex) {
            result = scriptedResults[nextIndex]
        } else {
            result = .success(
                serialNum: config.serialNum,
                displayID: CGDirectDisplayID(12_000 + createCallCount)
            )
        }
        nextIndex += 1

        switch result {
        case .success(let serialNum, let displayID):
            return FakeOrchestratorRuntimeHandle(serialNum: serialNum, displayID: displayID)
        case .failure(let error):
            throw error
        }
    }
}

@MainActor
private final class FakeOrchestratorRuntimeHandle: VirtualDisplayRuntimeHandling {
    let serialNum: UInt32
    let displayID: CGDirectDisplayID

    init(serialNum: UInt32, displayID: CGDirectDisplayID) {
        self.serialNum = serialNum
        self.displayID = displayID
    }

    func applyModes(_ modes: [ResolutionSelection]) -> Bool {
        !modes.isEmpty
    }
}
