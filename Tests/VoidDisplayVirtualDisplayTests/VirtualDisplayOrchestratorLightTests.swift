import CoreGraphics
import Foundation
import Testing
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayFoundation
@testable import VoidDisplayVirtualDisplayTestingSupport

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
    func setDesiredEnabledPersistsDesiredDisabled() throws {
        let store = FakeVirtualDisplayStore()
        let config = makeConfig(serial: 25, displayName: "用户配置 25")
        let sut = makeOrchestrator(store: store, initialConfigs: [config])

        try sut.setDesiredEnabled(config.id, enabled: false)

        #expect(store.savedConfigs.count == 1)
        #expect(sut.snapshot.configs.first?.desiredEnabled == false)
        #expect(sut.snapshot.configs.first?.displayName == "用户配置 25")
    }

    @Test
    func disableMainDisplayTriggersAggressiveRecoveryOnReenable() async throws {
        let mainID = CGMainDisplayID()
        let peerID: CGDirectDisplayID = mainID == 0 ? 1 : mainID &+ 1
        var configMain = makeConfig(serial: 125, displayName: "Main")
        var configPeer = makeConfig(serial: 126, displayName: "Peer")
        configMain.desiredEnabled = false
        configPeer.desiredEnabled = false
        let driver = FakeOrchestratorRuntimeDriver(
            scriptedResults: [
                .success(serialNum: configMain.serialNum, displayID: mainID),
                .success(serialNum: configPeer.serialNum, displayID: peerID),
                .success(serialNum: configMain.serialNum, displayID: mainID),
                .success(serialNum: configPeer.serialNum, displayID: peerID)
            ]
        )
        let snapshot = DisplayTopologySnapshot(
            mainDisplayID: mainID,
            displays: [
                .init(
                    id: mainID,
                    serialNumber: configMain.serialNum,
                    isManagedVirtualDisplay: true,
                    isActive: true,
                    isInMirrorSet: false,
                    mirrorMasterDisplayID: nil,
                    bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
                ),
                .init(
                    id: peerID,
                    serialNumber: configPeer.serialNum,
                    isManagedVirtualDisplay: true,
                    isActive: true,
                    isInMirrorSet: false,
                    mirrorMasterDisplayID: nil,
                    bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
                )
            ]
        )
        let sut = makeOrchestrator(
            store: FakeVirtualDisplayStore(),
            initialConfigs: [configMain, configPeer],
            inspector: StableTopologyInspector(snapshot: snapshot),
            runtimeDriver: driver
        )

        try sut.setDesiredEnabled(configMain.id, enabled: true)
        _ = try await sut.enableRuntimeDisplay(configMain.id)
        try sut.setDesiredEnabled(configPeer.id, enabled: true)
        _ = try await sut.enableRuntimeDisplay(configPeer.id)
        #expect(driver.createCallCount == 2)

        try sut.setDesiredEnabled(configMain.id, enabled: false)
        _ = try sut.disableRuntimeDisplayByConfig(configMain.id)
        try sut.setDesiredEnabled(configMain.id, enabled: true)
        _ = try await sut.enableRuntimeDisplay(configMain.id)

        #expect(driver.createCallCount == 4)
        #expect(Set(sut.snapshot.runningConfigIds) == Set([configMain.id, configPeer.id]))
        #expect(sut.snapshot.runtimeDisplayID(for: configMain.id) == mainID)
        #expect(sut.snapshot.runtimeDisplayID(for: configPeer.id) == peerID)
    }

    @Test
    func enableRuntimeDisplayRequiresTrueOfflineConfirmationBeforeRecreate() async throws {
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

        try sut.setDesiredEnabled(config.id, enabled: true)
        _ = try await sut.enableRuntimeDisplay(config.id)
        #expect(driver.createCallCount == 1)

        displayOnline = true
        try sut.setDesiredEnabled(config.id, enabled: false)
        _ = try sut.disableRuntimeDisplayByConfig(config.id)
        try sut.setDesiredEnabled(config.id, enabled: true)

        do {
            _ = try await sut.enableRuntimeDisplay(config.id)
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
    func createDisplayCommandSuccessReturnsCommandFacts() throws {
        let store = FakeVirtualDisplayStore()
        let driver = FakeOrchestratorRuntimeDriver(
            scriptedResults: [.success(serialNum: 50, displayID: 950)]
        )
        let sut = makeOrchestrator(store: store, runtimeDriver: driver)

        let result = try sut.createDisplayCommand(
            name: "Created",
            serialNum: 50,
            physicalSize: CGSize(width: 300, height: 200),
            maxPixels: (width: 1920, height: 1080),
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
        )

        #expect(result.createdConfigID != nil)
        #expect(result.persistenceOutcome == .saved)
        #expect(result.runtimeCreationOutcome == .succeeded)
        #expect(result.rollbackOutcome == .notAttempted)
        #expect(sut.snapshot.runtimeDisplayIDByConfigId[result.createdConfigID!] == 950)
    }

    @Test
    func createDisplayCommandRuntimeFailureRollsBackConfigAndReportsFacts() {
        let store = FakeVirtualDisplayStore()
        let driver = FakeOrchestratorRuntimeDriver(
            scriptedResults: [.failure(VirtualDisplayOperationError.creationFailed)]
        )
        let sut = makeOrchestrator(store: store, runtimeDriver: driver)

        do {
            _ = try sut.createDisplayCommand(
                name: "Rollback OK",
                serialNum: 51,
                physicalSize: CGSize(width: 300, height: 200),
                maxPixels: (width: 1920, height: 1080),
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
            Issue.record("Expected creationFailed error.")
        } catch let error as VirtualDisplayCreateCommandFailure {
            #expect(error.reason == "runtime_creation_failed")
            #expect(error.result.createdConfigID != nil)
            #expect(error.result.persistenceOutcome == .rolledBack)
            #expect(error.result.runtimeCreationOutcome == .failed)
            #expect(error.result.rollbackOutcome == .rolledBack)
            guard let underlying = error.underlyingError as? VirtualDisplayOperationError,
                  case .creationFailed = underlying
            else {
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
    func deleteDisplayCommandMissingConfigFailsConfigNotFound() {
        let sut = makeOrchestrator(store: FakeVirtualDisplayStore())
        let missingID = UUID()

        do {
            _ = try sut.deleteDisplayCommand(missingID)
            Issue.record("Expected config_not_found failure.")
        } catch let error as VirtualDisplayDeleteCommandFailure {
            #expect(error.reason == "config_not_found")
            #expect(error.result.configID == missingID)
            #expect(error.result.persistenceOutcome == .notAttempted)
            #expect(error.result.runtimeTrackingClearOutcome == .notAttempted)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func deleteDisplayCommandClearsConfigAndPersists() throws {
        let store = FakeVirtualDisplayStore()
        let config = makeConfig(serial: 12, displayName: "Destroy")
        let sut = makeOrchestrator(store: store, initialConfigs: [config])

        let result = try sut.deleteDisplayCommand(config.id)

        #expect(store.savedConfigs.count == 1)
        #expect(sut.snapshot.configs.isEmpty)
        #expect(sut.snapshot.runtimeDisplayID(for: config.id) == nil)
        #expect(result.configID == config.id)
        #expect(result.persistenceOutcome == .saved)
        #expect(result.runtimeTrackingClearOutcome == .cleared)
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
    func resetDuringRebuildRetryDoesNotRecreateRemovedConfig() async throws {
        let store = FakeVirtualDisplayStore()
        let config = makeConfig(serial: 63, displayName: "Reset During Retry")
        let driver = FakeOrchestratorRuntimeDriver(
            scriptedResults: [
                .failure(VirtualDisplayOperationError.creationFailed),
                .success(serialNum: config.serialNum, displayID: 963)
            ]
        )
        let clock = ResettingVirtualDisplayClock()
        let sut = makeOrchestrator(
            store: store,
            initialConfigs: [config],
            runtimeDriver: driver,
            clock: clock
        )
        var createCallCountAtReset = 0
        var resetResult: Result<Int, Error>?
        clock.onFirstSleep = {
            createCallCountAtReset = driver.createCallCount
            resetResult = Result { try sut.resetAllVirtualDisplayData() }
        }

        do {
            try await sut.rebuildVirtualDisplay(configId: config.id)
            Issue.record("Expected rebuild to stop after reset removed its configuration.")
        } catch let error as VirtualDisplayOperationError {
            guard case .configNotFound = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(createCallCountAtReset == 1)
        #expect(try resetResult?.get() == 1)
        #expect(driver.createCallCount == 1)
        #expect(sut.snapshot.configs.isEmpty)
        #expect(sut.snapshot.runningConfigIds.isEmpty)
    }

    @Test
    func startupRestoreCommandRestoresSingleDesiredConfig() {
        let store = FakeVirtualDisplayStore()
        let config = makeConfig(serial: 64, displayName: "Desired")
        let driver = FakeOrchestratorRuntimeDriver(
            scriptedResults: [.success(serialNum: 64, displayID: 964)]
        )
        let sut = makeOrchestrator(
            store: store,
            initialConfigs: [config],
            runtimeDriver: driver
        )

        let result = sut.restoreVirtualDisplayForStartupCommand(
            startupRestoreRequest(config: config)
        )

        #expect(result.configID == config.id)
        #expect(result.restoreOutcome == .succeeded)
        #expect(result.postDisplayID == 964)
        #expect(sut.snapshot.runningConfigIds == [config.id])
        #expect(driver.createCallCount == 1)
        #expect(sut.snapshot.restoreFailures.isEmpty)
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
        clock: (any VirtualDisplayClocking)? = nil,
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
            runtimeDriver: runtimeDriver ?? TestVirtualDisplayRuntimeDriver(),
            clock: clock
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

    func startupRestoreRequest(config: VirtualDisplayConfig) -> VirtualDisplayStartupRestoreCommandRequest {
        return VirtualDisplayStartupRestoreCommandRequest(
            transactionID: UUID(),
            runID: UUID(),
            configID: config.id
        )
    }

}

@MainActor
private final class ResettingVirtualDisplayClock: VirtualDisplayClocking {
    var onFirstSleep: (() -> Void)?

    private var currentTime: TimeInterval = 0
    private var didRunFirstSleep = false

    func now() -> TimeInterval {
        currentTime
    }

    func sleep(for duration: Duration) async {
        if !didRunFirstSleep {
            didRunFirstSleep = true
            onFirstSleep?()
        }
        let components = duration.components
        currentTime += max(
            0,
            Double(components.seconds) +
                Double(components.attoseconds) / 1_000_000_000_000_000_000
        )
        await Task.yield()
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
        trackedManagedSerials _: Set<UInt32>,
        managedVendorID _: UInt32,
        managedProductID _: UInt32
    ) -> DisplayTopologySnapshot? {
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
        descriptor: VirtualDisplayRuntimeDescriptor,
        onTermination _: @escaping @MainActor () -> Void
    ) throws -> any VirtualDisplayRuntimeHandling {
        createCallCount += 1
        let result: CreateResult
        if scriptedResults.indices.contains(nextIndex) {
            result = scriptedResults[nextIndex]
        } else {
            result = .success(
                serialNum: descriptor.serialNumber,
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

    func applyModes(_ modes: [VirtualDisplayRuntimeMode]) -> Bool {
        !modes.isEmpty
    }
}
