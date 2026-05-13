@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayObservability
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import CoreGraphics
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct VirtualDisplayControllerTests {
    @Test func controllerExposesConfigStoreLoadFailureState() {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.configStoreState = .loadFailed(
            error: .unsupportedSchemaVersion(expected: 3, actual: 2),
            diagnostics: .init(
                primaryStoreURL: URL(fileURLWithPath: "/tmp/virtual-displays.json"),
                isTestIsolatedPath: true
            )
        )

        let env = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay
        )

        env.virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        #expect(env.virtualDisplay.configStorePresentation.hasLoadFailure)
        #expect(
            env.virtualDisplay.configStorePresentation.loadErrorMessage
                == VirtualDisplayConfigStoreError
                .unsupportedSchemaVersion(expected: 3, actual: 2)
                .userFacingMessage
        )
        #expect(env.virtualDisplay.configStorePresentation.diagnosticsSummary?.contains("primary=/tmp/virtual-displays.json") == true)
    }

    @Test func rebuildFromSavedConfigDoesNotApplyModesAgainAfterRebuild() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()

        let config = VirtualDisplayConfig(
            displayName: "Running",
            serialNum: 7,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [config]
        virtualDisplay.currentRunningConfigIds = [config.id]

        let sut = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay
        )

        sut.virtualDisplay.startRebuildFromSavedConfig(configId: config.id)

        let rebuildTriggered = await waitUntil {
            virtualDisplay.rebuildVirtualDisplayCallCount == 1
        }
        let rebuildPresentationSettled = await waitUntil {
            !sut.virtualDisplay.isRebuilding(configId: config.id)
        }

        #expect(rebuildTriggered)
        #expect(rebuildPresentationSettled)
        #expect(virtualDisplay.rebuildVirtualDisplayConfigIds == [config.id])
        #expect(virtualDisplay.applyModesCallCount == 0)
    }

    @Test func startRebuildDelegatesQuiesceToInjectedExecutor() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()

        let config = VirtualDisplayConfig(
            displayName: "Main Candidate",
            serialNum: 9,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let displayID: CGDirectDisplayID = 4321

        virtualDisplay.currentDisplayConfigs = [config]
        virtualDisplay.currentRunningConfigIds = [config.id]
        virtualDisplay.runtimeDisplayIDByConfigId[config.id] = displayID
        sharing.activeSharingDisplayIDs = [displayID]

        let sut = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay
        )

        sut.virtualDisplay.startRebuildFromSavedConfig(configId: config.id)

        let rebuildTriggered = await waitUntil {
            virtualDisplay.rebuildVirtualDisplayCallCount == 1
        }

        #expect(rebuildTriggered)
        #expect(sharing.stopSharingCallCount == 0)
        #expect(capture.removeByDisplayCallCount == 0)
        #expect(capture.removedDisplayIDs.isEmpty)
    }

    @Test func startRebuildForwardsConcurrentDuplicateRequestsToExecutor() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.rebuildDelayNanoseconds = 150_000_000

        let config = VirtualDisplayConfig(
            displayName: "Concurrent",
            serialNum: 10,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [config]
        virtualDisplay.currentRunningConfigIds = [config.id]

        let sut = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay
        )

        sut.virtualDisplay.startRebuildFromSavedConfig(configId: config.id)
        sut.virtualDisplay.startRebuildFromSavedConfig(configId: config.id)

        let duplicateForwarded = await waitUntil {
            virtualDisplay.rebuildVirtualDisplayCallCount == 2
        }
        #expect(duplicateForwarded)

        let settled = await waitUntil {
            !sut.virtualDisplay.isRebuilding(configId: config.id)
        }
        #expect(settled)
    }

    @Test func startRebuildForwardsMissingConfigToExecutor() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        let missingConfigID = UUID()

        let sut = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay
        )

        sut.virtualDisplay.startRebuildFromSavedConfig(configId: missingConfigID)

        let forwarded = await waitUntil {
            virtualDisplay.rebuildVirtualDisplayConfigIds == [missingConfigID]
        }
        #expect(forwarded)
    }

    @Test func rebuildFailureRetryAndAppliedBadgeLifecycle() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()

        let config = VirtualDisplayConfig(
            displayName: "Retry",
            serialNum: 11,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [config]
        virtualDisplay.currentRunningConfigIds = [config.id]
        virtualDisplay.rebuildVirtualDisplayError = NSError(domain: "test", code: 33)

        let sut = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            appliedBadgeDisplayDuration: .milliseconds(50)
        )

        sut.virtualDisplay.startRebuildFromSavedConfig(configId: config.id)

        let failed = await waitUntil {
            sut.virtualDisplay.rebuildFailureMessage(configId: config.id) != nil
        }
        #expect(failed)
        #expect(sut.virtualDisplay.hasRecentApplySuccess(configId: config.id) == false)

        virtualDisplay.rebuildVirtualDisplayError = nil
        sut.virtualDisplay.retryRebuild(configId: config.id)

        let retried = await waitUntil {
            virtualDisplay.rebuildVirtualDisplayCallCount == 2
        }
        #expect(retried)

        let successPresented = await waitUntil {
            sut.virtualDisplay.hasRecentApplySuccess(configId: config.id)
        }
        #expect(successPresented)
        #expect(sut.virtualDisplay.rebuildFailureMessage(configId: config.id) == nil)

        let successCleared = await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            !sut.virtualDisplay.hasRecentApplySuccess(configId: config.id)
        }
        #expect(successCleared)
    }

    @Test func moveDisplayConfigTriggersMainDisplayPolicyReconcile() async throws {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.moveConfigResult = true
        virtualDisplay.currentDisplayConfigs = [
            VirtualDisplayConfig(
                displayName: "A",
                serialNum: 1,
                physicalWidth: 300,
                physicalHeight: 200,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
                desiredEnabled: true
            ),
            VirtualDisplayConfig(
                displayName: "B",
                serialNum: 2,
                physicalWidth: 300,
                physicalHeight: 200,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
                desiredEnabled: true
            )
        ]

        let sut = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay
        )

        let moved = try sut.virtualDisplay.moveDisplayConfig(
            virtualDisplay.currentDisplayConfigs[1].id,
            direction: .up
        )
        #expect(moved)

        let reconciled = await waitUntil {
            virtualDisplay.reconcileMainDisplayPolicyIfNeededCallCount == 1
        }
        #expect(reconciled)
    }

    @Test func moveDisplayConfigSkipsReconcileWhenFirstEnabledConfigDoesNotChange() async throws {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.moveConfigResult = true
        var configA = VirtualDisplayConfig(
            displayName: "A",
            serialNum: 1,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        var configB = VirtualDisplayConfig(
            displayName: "B",
            serialNum: 2,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        var configC = VirtualDisplayConfig(
            displayName: "C",
            serialNum: 3,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        configA.desiredEnabled = true
        configB.desiredEnabled = true
        configC.desiredEnabled = true
        virtualDisplay.currentDisplayConfigs = [configA, configB, configC]

        let sut = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay
        )
        sut.virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        let moved = try sut.virtualDisplay.moveDisplayConfig(configC.id, direction: .up)
        #expect(moved)

        await drainMainActorTasks()
        #expect(virtualDisplay.reconcileMainDisplayPolicyIfNeededCallCount == 0)
    }

    @Test func setPrimaryVirtualDisplayByReorderingMovesTargetToFirstEnabledAndReconciles() async throws {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.moveConfigResult = true
        var disabled = VirtualDisplayConfig(
            displayName: "Disabled",
            serialNum: 9,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let configA = VirtualDisplayConfig(
            displayName: "A",
            serialNum: 1,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let configB = VirtualDisplayConfig(
            displayName: "B",
            serialNum: 2,
            physicalWidth: 300,
            physicalHeight: 200,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
                desiredEnabled: true
            )
        disabled.desiredEnabled = false
        virtualDisplay.currentDisplayConfigs = [disabled, configA, configB]

        let sut = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay
        )

        let changed = try sut.virtualDisplay.setPrimaryVirtualDisplayByReordering(configB.id)
        #expect(changed)
        #expect(virtualDisplay.currentDisplayConfigs.map(\.id) == [disabled.id, configB.id, configA.id])
        #expect(virtualDisplay.moveConfigToFirstEnabledPositionCallCount == 1)
        #expect(virtualDisplay.moveConfigToFirstEnabledPositionIDs == [configB.id])

        let reconciled = await waitUntil {
            virtualDisplay.reconcileMainDisplayPolicyIfNeededCallCount == 1
        }
        #expect(reconciled)
    }

    @Test func setPrimaryVirtualDisplayByReorderingNoOpsWhenAlreadyFirstEnabled() async throws {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.moveConfigResult = true
        let configA = VirtualDisplayConfig(
            displayName: "A",
            serialNum: 1,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let configB = VirtualDisplayConfig(
            displayName: "B",
            serialNum: 2,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [configA, configB]

        let sut = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay
        )

        let changed = try sut.virtualDisplay.setPrimaryVirtualDisplayByReordering(configA.id)
        #expect(changed == false)
        #expect(virtualDisplay.moveConfigToFirstEnabledPositionCallCount == 1)

        await drainMainActorTasks()
        #expect(virtualDisplay.reconcileMainDisplayPolicyIfNeededCallCount == 0)
    }

    @Test func setPrimaryVirtualDisplayByReorderingNoOpsWhenTargetDisabled() async throws {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.moveConfigResult = true
        var disabled = VirtualDisplayConfig(
            displayName: "Disabled",
            serialNum: 1,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let enabled = VirtualDisplayConfig(
            displayName: "Enabled",
            serialNum: 2,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        disabled.desiredEnabled = false
        virtualDisplay.currentDisplayConfigs = [disabled, enabled]

        let sut = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay
        )

        let changed = try sut.virtualDisplay.setPrimaryVirtualDisplayByReordering(disabled.id)
        #expect(changed == false)
        #expect(virtualDisplay.moveConfigToFirstEnabledPositionCallCount == 1)
        #expect(virtualDisplay.currentDisplayConfigs.map(\.id) == [disabled.id, enabled.id])

        await drainMainActorTasks()
        #expect(virtualDisplay.reconcileMainDisplayPolicyIfNeededCallCount == 0)
    }

    @Test func virtualDisplayFacadeResetDelegatesToOrchestrator() throws {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()

        virtualDisplay.currentDisplayConfigs = [
            VirtualDisplayConfig(
                displayName: "Cleanup",
                serialNum: 123,
                physicalWidth: 300,
                physicalHeight: 200,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
                desiredEnabled: true
            )
        ]

        let sut = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay
        )

        let removed = try sut.virtualDisplay.resetVirtualDisplayData()
        #expect(removed == 1)
        #expect(virtualDisplay.resetAllVirtualDisplayDataCallCount == 1)
    }

    @Test func virtualDisplayFacadeResetPropagatesFailureWithoutClearingControllerState() {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        let config = VirtualDisplayConfig(
            displayName: "Keep State",
            serialNum: 124,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [config]
        virtualDisplay.resetAllVirtualDisplayDataError = NSError(domain: "VirtualDisplayControllerTests", code: 70)

        let sut = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay
        )

        #expect(throws: Error.self) {
            _ = try sut.virtualDisplay.resetVirtualDisplayData()
        }
        #expect(virtualDisplay.resetAllVirtualDisplayDataCallCount == 1)
        #expect(sut.virtualDisplay.displayConfigs.map(\.id) == [config.id])
        #expect(sut.virtualDisplay.persistenceAlert != nil)
        #expect(sut.virtualDisplay.persistenceAlert?.message.isEmpty == false)
    }

    @Test func updateConfigPropagatesFacadeFailureWithoutMutatingControllerState() {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        let config = VirtualDisplayConfig(
            displayName: "Original",
            serialNum: 125,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [config]
        virtualDisplay.updateConfigError = NSError(domain: "VirtualDisplayControllerTests", code: 71)

        let sut = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay
        )

        var updated = config
        updated.displayName = "Updated"

        #expect(throws: Error.self) {
            try sut.virtualDisplay.updateConfig(updated)
        }
        #expect(sut.virtualDisplay.displayConfigs.first?.displayName == "Original")
        #expect(sut.virtualDisplay.persistenceAlert != nil)
        #expect(sut.virtualDisplay.persistenceAlert?.message.isEmpty == false)
    }

    @Test func createVirtualDisplayPropagatesFailureAndSetsPersistencePresentation() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        let existing = VirtualDisplayConfig(
            displayName: "Existing",
            serialNum: 126,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [existing]
        let createError = NSError(domain: "VirtualDisplayControllerTests", code: 72)

        let sut = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay
        )
        sut.virtualDisplay.configureCreateExecutor { _ in
            throw createError
        }

        await #expect(throws: Error.self) {
            _ = try await sut.virtualDisplay.createVirtualDisplay(
                VirtualDisplayCreateRequest(
                    displayName: "New",
                    serialNumber: 127,
                    physicalWidthMillimeters: 300,
                    physicalHeightMillimeters: 200,
                    maximumPixelWidth: 1920,
                    maximumPixelHeight: 1080,
                    modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
                )
            )
        }
        #expect(sut.virtualDisplay.displayConfigs.map(\.id) == [existing.id])
        #expect(sut.virtualDisplay.persistenceAlert != nil)
        #expect(sut.virtualDisplay.persistenceAlert?.message.isEmpty == false)
    }

    @Test func createVirtualDisplayRecoveryFailureIsPresentedAsSuccess() async throws {
        let virtualDisplay = MockVirtualDisplayFacade()
        let sut = makeControllerEnvironment(
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: virtualDisplay
        )
        let createdID = UUID()
        sut.virtualDisplay.configureCreateExecutor { _ in
            VirtualDisplayCreateTransactionResult(
                transactionID: UUID(),
                status: .completedWithRecoveryFailures,
                createdConfigID: createdID,
                virtualDisplayCommandSucceeded: true
            )
        }

        let result = try await sut.virtualDisplay.createVirtualDisplay(
            VirtualDisplayCreateRequest(
                displayName: "Recovered",
                serialNumber: 1271,
                physicalWidthMillimeters: 300,
                physicalHeightMillimeters: 200,
                maximumPixelWidth: 1920,
                maximumPixelHeight: 1080,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
        )

        #expect(result == createdID)
        #expect(sut.virtualDisplay.persistenceAlert == nil)
    }

    @Test func createVirtualDisplayRollbackFailureUsesLocalizedPersistenceRecoveryErrorMessage() async {
        let store = FakeVirtualDisplayStore()
        store.scriptedSaveErrors = [
            nil,
            VirtualDisplayConfigStoreError.ioFailed(
                operation: "save",
                underlying: NSError(domain: "VirtualDisplayControllerTests", code: 76)
            )
        ]
        let orchestrator = VirtualDisplayOrchestrator(
            configRepository: VirtualDisplayConfigRepository(store: store, reportFailure: nil),
            displayReconfigurationMonitor: FakeDisplayReconfigurationMonitor(),
            managedDisplayOnlineChecker: { _ in false },
            runtimeDriver: ControllerTestRuntimeDriver(
                scriptedResults: [.failure(VirtualDisplayOperationError.creationFailed)]
            ),
            clock: nil
        )

        let sut = VirtualDisplayController(
            virtualDisplayFacade: orchestrator,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        sut.configureCreateExecutor { [weak sut] request in
            guard let sut else {
                throw NSError(domain: "VirtualDisplayControllerTests", code: 77)
            }
            let result = try sut.createDisplayCommand(request)
            return VirtualDisplayCreateTransactionResult(
                transactionID: UUID(),
                status: .completed,
                createdConfigID: result.createdConfigID,
                virtualDisplayCommandSucceeded: result.runtimeCreationOutcome == .succeeded
            )
        }

        await #expect(throws: Error.self) {
            _ = try await sut.createVirtualDisplay(
                VirtualDisplayCreateRequest(
                    displayName: "New",
                    serialNumber: 200,
                    physicalWidthMillimeters: 300,
                    physicalHeightMillimeters: 200,
                    maximumPixelWidth: 1920,
                    maximumPixelHeight: 1080,
                    modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
                )
            )
        }
        #expect(sut.persistenceAlert != nil)
        #expect(
            sut.persistenceAlert?.message ==
                String(
                    localized: "Create failed and the config rollback could not be saved. Check config file permissions or reset the config file."
                )
        )
        #expect(sut.displayConfigs.count == 1)
    }

    @Test func moveDisplayConfigPropagatesFailureAndSetsPersistencePresentation() {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        let configA = VirtualDisplayConfig(
            displayName: "A",
            serialNum: 127,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let configB = VirtualDisplayConfig(
            displayName: "B",
            serialNum: 128,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [configA, configB]
        virtualDisplay.moveConfigError = NSError(domain: "VirtualDisplayControllerTests", code: 73)

        let sut = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay
        )

        #expect(throws: Error.self) {
            _ = try sut.virtualDisplay.moveDisplayConfig(configB.id, direction: .up)
        }
        #expect(sut.virtualDisplay.displayConfigs.map(\.id) == [configA.id, configB.id])
        #expect(sut.virtualDisplay.persistenceAlert != nil)
        #expect(sut.virtualDisplay.persistenceAlert?.message.isEmpty == false)
    }

    @Test func setPrimaryVirtualDisplayByReorderingPropagatesFailureAndSetsPersistencePresentation() {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        var disabled = VirtualDisplayConfig(
            displayName: "Disabled",
            serialNum: 129,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let enabled = VirtualDisplayConfig(
            displayName: "Enabled",
            serialNum: 130,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        disabled.desiredEnabled = false
        virtualDisplay.currentDisplayConfigs = [disabled, enabled]
        virtualDisplay.moveConfigToFirstEnabledPositionError = NSError(
            domain: "VirtualDisplayControllerTests",
            code: 74
        )

        let sut = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay
        )

        #expect(throws: Error.self) {
            _ = try sut.virtualDisplay.setPrimaryVirtualDisplayByReordering(enabled.id)
        }
        #expect(sut.virtualDisplay.displayConfigs.map(\.id) == [disabled.id, enabled.id])
        #expect(sut.virtualDisplay.persistenceAlert != nil)
        #expect(sut.virtualDisplay.persistenceAlert?.message.isEmpty == false)
    }

    @Test func commandOnlySaveConfigForRebuildDoesNotSetPersistenceAlertOrCallUpdateConfig() throws {
        let virtualDisplay = MockVirtualDisplayFacade()
        let config = VirtualDisplayConfig(
            displayName: "Loaded",
            serialNum: 131,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        var edited = config
        edited.displayName = "Edited"
        virtualDisplay.currentDisplayConfigs = [config]
        let sut = makeControllerEnvironment(
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: virtualDisplay
        )

        let previous = try sut.virtualDisplay.saveConfigForRebuildCommand(
            edited,
            expectedConfigFingerprint: config.editRebuildFingerprint
        )

        #expect(previous.displayName == "Loaded")
        #expect(virtualDisplay.configForEditRebuildIDs == [config.id])
        #expect(virtualDisplay.saveConfigForRebuildCallCount == 1)
        #expect(virtualDisplay.updateConfigCallCount == 0)
        #expect(sut.virtualDisplay.persistenceAlert == nil)
    }

    @Test func commandOnlySaveConfigForRebuildStaleFailsBeforeSaving() {
        let virtualDisplay = MockVirtualDisplayFacade()
        let config = VirtualDisplayConfig(
            displayName: "Loaded",
            serialNum: 132,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [config]
        let sut = makeControllerEnvironment(
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: virtualDisplay
        )

        #expect(throws: VirtualDisplayEditRebuildPersistenceError.self) {
            _ = try sut.virtualDisplay.saveConfigForRebuildCommand(
                config,
                expectedConfigFingerprint: "stale"
            )
        }

        #expect(virtualDisplay.saveConfigForRebuildCallCount == 0)
        #expect(sut.virtualDisplay.persistenceAlert == nil)
    }

    @Test func saveConfigAndRebuildSendsSingleExecutorRequest() async throws {
        let virtualDisplay = MockVirtualDisplayFacade()
        let config = VirtualDisplayConfig(
            displayName: "Runtime Edit",
            serialNum: 133,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [config]
        let sut = makeControllerEnvironment(
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: virtualDisplay
        ).virtualDisplay
        var requestCount = 0
        sut.configureEditRebuildExecutor { updatedConfig, expectedFingerprint, source in
            requestCount += 1
            #expect(updatedConfig.id == config.id)
            #expect(expectedFingerprint == config.editRebuildFingerprint)
            #expect(source == .editSaveAndRebuild)
            return editRebuildHandle(
                configID: config.id,
                status: .completed,
                virtualDisplayCommandSucceeded: true
            )
        }

        let handle = try await sut.saveConfigAndRebuild(
            config,
            expectedConfigFingerprint: config.editRebuildFingerprint,
            source: .editSaveAndRebuild
        )
        _ = try await handle.waitForSaveGate()

        #expect(requestCount == 1)
        #expect(virtualDisplay.updateConfigCallCount == 0)
        #expect(virtualDisplay.rebuildVirtualDisplayCallCount == 0)
    }

    @Test func editRebuildPresentationWaitsForTerminalResultBeforeSuccess() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Presentation",
            serialNum: 134,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.currentDisplayConfigs = [config]
        let sut = makeControllerEnvironment(
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: virtualDisplay,
            appliedBadgeDisplayDuration: .milliseconds(50)
        ).virtualDisplay
        let handle = editRebuildHandle(
            configID: config.id,
            status: .completed,
            virtualDisplayCommandSucceeded: true,
            terminalDelayNanoseconds: 80_000_000
        )

        sut.startEditRebuildPresentation(configId: config.id, handle: handle)

        #expect(sut.isRebuilding(configId: config.id))
        #expect(sut.hasRecentApplySuccess(configId: config.id) == false)
        let completed = await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            sut.hasRecentApplySuccess(configId: config.id)
        }
        #expect(completed)
        #expect(!sut.isRebuilding(configId: config.id))
    }

    @Test func editRebuildFailureIsPresentedAsRebuildFailureNotSaveFailure() async {
        let config = VirtualDisplayConfig(
            displayName: "Presentation Failure",
            serialNum: 135,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.currentDisplayConfigs = [config]
        let sut = makeControllerEnvironment(
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: virtualDisplay
        ).virtualDisplay

        sut.startEditRebuildPresentation(
            configId: config.id,
            handle: editRebuildHandle(
                configID: config.id,
                status: .failed,
                virtualDisplayCommandSucceeded: false
            )
        )

        let failed = await waitUntil {
            sut.rebuildFailureMessage(configId: config.id) != nil
        }
        #expect(failed)
        #expect(sut.persistenceAlert == nil)
    }

    @Test func dismissPersistenceAlertResetsControllerPresentationState() {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.resetAllVirtualDisplayDataError = NSError(domain: "VirtualDisplayControllerTests", code: 75)

        let sut = makeControllerEnvironment(
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay
        )

        #expect(throws: Error.self) {
            _ = try sut.virtualDisplay.resetVirtualDisplayData()
        }
        #expect(sut.virtualDisplay.persistenceAlert != nil)

        sut.virtualDisplay.dismissPersistenceAlert()

        #expect(sut.virtualDisplay.persistenceAlert == nil)
    }
}

private struct ControllerTestEnvironment {
    let virtualDisplay: VirtualDisplayController
}

@MainActor
private func makeControllerEnvironment(
    captureMonitoringService capture: MockCaptureMonitoringService,
    sharingService sharing: MockSharingService,
    virtualDisplayFacade: any VirtualDisplayFacade,
    appliedBadgeDisplayDuration: Duration = .seconds(2.5)
) -> ControllerTestEnvironment {
    let controller = VirtualDisplayController(
        virtualDisplayFacade: virtualDisplayFacade,
        appliedBadgeDisplayDuration: appliedBadgeDisplayDuration
    )
    controller.configureRebuildExecutor { [weak controller] configID, _ in
        guard let controller else { return }
        try await controller.rebuildVirtualDisplay(configId: configID)
    }
    return ControllerTestEnvironment(virtualDisplay: controller)
}

private func editRebuildHandle(
    configID: UUID,
    status: VirtualDisplayEditRebuildTransactionStatus,
    virtualDisplayCommandSucceeded: Bool,
    terminalDelayNanoseconds: UInt64 = 0
) -> VirtualDisplayEditRebuildTransactionHandle {
    let transactionID = UUID()
    return VirtualDisplayEditRebuildTransactionHandle(
        transactionID: transactionID,
        saveGateTask: Task {
            VirtualDisplayEditRebuildSaveGateResult(
                transactionID: transactionID,
                configID: configID
            )
        },
        terminalResultTask: Task {
            if terminalDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: terminalDelayNanoseconds)
            }
            return VirtualDisplayEditRebuildTransactionResult(
                transactionID: transactionID,
                status: status,
                virtualDisplayCommandSucceeded: virtualDisplayCommandSucceeded
            )
        }
    )
}

@MainActor
private final class FakeDisplayReconfigurationMonitor: DisplayReconfigurationMonitoring {
    @discardableResult
    func start(handler: @escaping @MainActor () -> Void) -> Bool {
        handler()
        return true
    }

    func stop() {}
}

@MainActor
private final class ControllerTestRuntimeDriver: VirtualDisplayRuntimeDriving {
    enum CreateResult {
        case success(serialNum: UInt32, displayID: CGDirectDisplayID)
        case failure(Error)
    }

    private let scriptedResults: [CreateResult]
    private var nextIndex = 0

    init(scriptedResults: [CreateResult]) {
        self.scriptedResults = scriptedResults
    }

    func createRuntimeDisplay(
        from config: VirtualDisplayConfig,
        maxPixels _: (width: UInt32, height: UInt32)?,
        onTermination _: @escaping @MainActor () -> Void
    ) throws -> any VirtualDisplayRuntimeHandling {
        let result: CreateResult
        if scriptedResults.indices.contains(nextIndex) {
            result = scriptedResults[nextIndex]
        } else {
            result = .success(serialNum: config.serialNum, displayID: 20_000)
        }
        nextIndex += 1

        switch result {
        case .success(let serialNum, let displayID):
            return ControllerTestRuntimeHandle(serialNum: serialNum, displayID: displayID)
        case .failure(let error):
            throw error
        }
    }
}

@MainActor
private final class ControllerTestRuntimeHandle: VirtualDisplayRuntimeHandling {
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
