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

    @Test(arguments: [false, true])
    func updateConfigPreservesEnabledIntentChangedAfterEditingStarted(latestEnabled: Bool) throws {
        let facade = MockVirtualDisplayFacade()
        var draft = VirtualDisplayConfig(
            displayName: "Original",
            serialNum: 125,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: !latestEnabled
        )
        facade.currentDisplayConfigs = [draft]
        let sut = makeControllerEnvironment(virtualDisplayFacade: facade)

        try facade.setDesiredEnabled(draft.id, enabled: latestEnabled)
        facade.currentRunningConfigIds = latestEnabled ? [draft.id] : []
        draft.displayName = "Edited"
        draft.serialNum = 126
        draft.physicalWidth = 310
        draft.physicalHeight = 210
        draft.modes = [.init(width: 2560, height: 1440, refreshRate: 60, enableHiDPI: true)]

        try sut.virtualDisplay.updateConfig(draft)

        var expected = draft
        expected.desiredEnabled = latestEnabled
        #expect(facade.currentDisplayConfigs == [expected])
        #expect(sut.virtualDisplay.displayConfigs == [expected])
        #expect(sut.virtualDisplay.isVirtualDisplayRunning(configId: draft.id) == latestEnabled)
        #expect(facade.setDesiredEnabledCallCount == 1)
        #expect(facade.enableRuntimeDisplayCallCount == 0)
        #expect(facade.disableRuntimeDisplayByConfigCallCount == 0)
        #expect(facade.rebuildVirtualDisplayCallCount == 0)
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
            virtualDisplayFacade: virtualDisplay,
            create: { _ in throw createError }
        )

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

    @Test func createVirtualDisplayReturnsSemanticExecutorID() async throws {
        let virtualDisplay = MockVirtualDisplayFacade()
        let createdID = UUID()
        let sut = makeControllerEnvironment(
            virtualDisplayFacade: virtualDisplay,
            create: { _ in
                createdID
            }
        )

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
        var requestCount = 0
        let sut = makeControllerEnvironment(
            virtualDisplayFacade: virtualDisplay,
            editAndRebuild: { updatedConfig, expectedFingerprint, source in
                requestCount += 1
                #expect(updatedConfig.id == config.id)
                #expect(expectedFingerprint == config.editRebuildFingerprint)
                #expect(source == .editSaveAndRebuild)
                return editRebuildOperation()
            }
        ).virtualDisplay

        let operation = try await sut.saveConfigAndRebuild(
            config,
            expectedConfigFingerprint: config.editRebuildFingerprint,
            source: .editSaveAndRebuild
        )
        try await operation.waitForSave()

        #expect(requestCount == 1)
        #expect(virtualDisplay.updateConfigCallCount == 0)
        #expect(virtualDisplay.rebuildVirtualDisplayCallCount == 0)
    }

    @Test func editRebuildRejectsInvalidModesBeforeBuildingRuntimeRequest() async {
        let facade = MockVirtualDisplayFacade()
        let original = VirtualDisplayConfig(
            displayName: "Edit Bounds", serialNum: 135, physicalWidth: 300, physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
        )
        facade.currentDisplayConfigs = [original]
        var requestCount = 0
        let controller = makeControllerEnvironment(virtualDisplayFacade: facade, editAndRebuild: { _, _, _ in
            requestCount += 1
            return editRebuildOperation()
        }).virtualDisplay
        for mode in [
            VirtualDisplayConfig.ModeConfig(width: 5000, height: 3000, refreshRate: 60, enableHiDPI: true),
            .init(width: 8193, height: 1, refreshRate: 60, enableHiDPI: false),
            .init(width: -1, height: 1080, refreshRate: 60, enableHiDPI: false),
            .init(width: 1920, height: 1080, refreshRate: .nan, enableHiDPI: false)
        ] {
            var edited = original
            edited.modes.append(mode)
            await #expect(throws: VirtualDisplayOperationError.self) {
                _ = try await controller.saveConfigAndRebuild(edited, expectedConfigFingerprint: original.editRebuildFingerprint)
            }
        }
        #expect(requestCount == 0)
        #expect(controller.getConfig(original.id) == original)
    }

    @Test func saveConfigAndRebuildRefreshesControllerAtSaveGate() async throws {
        let virtualDisplay = MockVirtualDisplayFacade()
        let original = VirtualDisplayConfig(
            displayName: "Before Save Gate",
            serialNum: 134,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        var updated = original
        updated.displayName = "After Save Gate"
        virtualDisplay.currentDisplayConfigs = [original]
        let controller = makeControllerEnvironment(
            virtualDisplayFacade: virtualDisplay,
            editAndRebuild: { _, _, _ in
                VirtualDisplayEditRebuildOperation(
                    saveTask: Task { @MainActor in
                        try await Task.sleep(for: .milliseconds(25))
                        virtualDisplay.currentDisplayConfigs = [updated]
                    },
                    completionTask: Task { @MainActor in
                        try await Task.sleep(for: .seconds(1))
                    }
                )
            }
        ).virtualDisplay

        let operation = try await controller.saveConfigAndRebuild(
            updated,
            expectedConfigFingerprint: original.editRebuildFingerprint,
            source: .editSaveAndRebuild
        )
        #expect(controller.getConfig(original.id)?.displayName == "Before Save Gate")

        try await operation.waitForSave()

        #expect(controller.getConfig(original.id)?.displayName == "After Save Gate")
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
        let operation = editRebuildOperation(
            terminalDelayNanoseconds: 80_000_000
        )

        sut.startEditRebuildPresentation(configId: config.id, operation: operation)

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
            operation: editRebuildOperation(
                completionError: NSError(
                    domain: "VirtualDisplayControllerTests",
                    code: 136
                )
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
    appliedBadgeDisplayDuration: Duration = .seconds(2.5),
    editAndRebuild: VirtualDisplayEditRebuildExecutor? = nil,
    create: VirtualDisplayCreateExecutor? = nil
) -> ControllerTestEnvironment {
    let controller = VirtualDisplayController(
        virtualDisplayFacade: virtualDisplayFacade,
        runtimeExecutors: testVirtualDisplayRuntimeExecutors(
            facade: virtualDisplayFacade,
            editAndRebuild: editAndRebuild,
            create: create
        ),
        appliedBadgeDisplayDuration: appliedBadgeDisplayDuration
    )
    return ControllerTestEnvironment(virtualDisplay: controller)
}

private func editRebuildOperation(
    completionError: (any Error)? = nil,
    terminalDelayNanoseconds: UInt64 = 0
) -> VirtualDisplayEditRebuildOperation {
    VirtualDisplayEditRebuildOperation(
        saveTask: Task {
        },
        completionTask: Task {
            if terminalDelayNanoseconds > 0 {
                try? await Task.sleep(for: .nanoseconds(terminalDelayNanoseconds))
            }
            if let completionError {
                throw completionError
            }
        }
    )
}
