@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayVirtualDisplayTestingSupport
@testable import VoidDisplayObservability
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct VirtualDisplayControllerTests {
    @Test func controllerExposesConfigStoreLoadFailureState() {
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.configStoreState = .loadFailed(
            error: .unsupportedSchemaVersion(expected: 3, actual: 2),
            diagnostics: .init(
                primaryStoreURL: URL(fileURLWithPath: "/tmp/virtual-displays.json"),
                isTestIsolatedPath: true
            )
        )

        let env = makeControllerEnvironment(
            virtualDisplayFacade: virtualDisplay
        )

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

    @Test func startRebuildForwardsConcurrentDuplicateRequestsToExecutor() async {
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
        let virtualDisplay = MockVirtualDisplayFacade()
        let missingConfigID = UUID()

        let sut = makeControllerEnvironment(
            virtualDisplayFacade: virtualDisplay
        )

        sut.virtualDisplay.startRebuildFromSavedConfig(configId: missingConfigID)

        let forwarded = await waitUntil {
            virtualDisplay.rebuildVirtualDisplayConfigIds == [missingConfigID]
        }
        #expect(forwarded)
    }

    @Test func rebuildFailureRetryAndAppliedBadgeLifecycle() async {
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

    @Test func virtualDisplayFacadeResetDelegatesToOrchestrator() throws {
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
            virtualDisplayFacade: virtualDisplay
        )

        let removed = try sut.virtualDisplay.resetVirtualDisplayData()
        #expect(removed == 1)
        #expect(virtualDisplay.resetAllVirtualDisplayDataCallCount == 1)
    }

    @Test func virtualDisplayFacadeResetPropagatesFailureWithoutClearingControllerState() {
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
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.resetAllVirtualDisplayDataError = NSError(domain: "VirtualDisplayControllerTests", code: 75)

        let sut = makeControllerEnvironment(
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
    virtualDisplayFacade: any VirtualDisplayFacade,
    appliedBadgeDisplayDuration: Duration = .seconds(2.5)
) -> ControllerTestEnvironment {
    let controller = VirtualDisplayController(
        virtualDisplayFacade: virtualDisplayFacade,
        appliedBadgeDisplayDuration: appliedBadgeDisplayDuration
    )
    controller.configureRebuildExecutor { configID, _ in
        try await virtualDisplayFacade.rebuildVirtualDisplay(configId: configID)
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
                try? await Task.sleep(for: .nanoseconds(terminalDelayNanoseconds))
            }
            return VirtualDisplayEditRebuildTransactionResult(
                transactionID: transactionID,
                status: status,
                virtualDisplayCommandSucceeded: virtualDisplayCommandSucceeded
            )
        }
    )
}
