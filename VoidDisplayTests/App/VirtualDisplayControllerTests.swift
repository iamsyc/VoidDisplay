import Testing
import CoreGraphics
@testable import VoidDisplay

@MainActor
@Suite(.serialized)
struct AppBootstrapTests {

    @Test func initPreviewModeSkipsStartupSequence() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()

        _ = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isRunningUnderXCTestOverride: false
        )

        #expect(virtualDisplay.loadPersistedConfigsCallCount == 0)
        #expect(virtualDisplay.restoreDesiredVirtualDisplaysCallCount == 0)
        #expect(sharing.startWebServiceCallCount == 0)
    }

    @Test func initUITestModeAppliesFixtureAndSkipsServiceBoot() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = UITestVirtualDisplayService(scenario: .baseline)

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            startupPlan: .init(
                shouldRestoreVirtualDisplays: true,
                shouldStartWebService: false,
                postRestoreConfiguration: nil
            ),
            isRunningUnderXCTestOverride: false
        )

        #expect(sharing.startWebServiceCallCount == 0)
        #expect(sut.virtualDisplay.displayConfigs.count == 2)
        #expect(sut.virtualDisplay.runningConfigIds.count == 1)
    }

    @Test func initRunningUnderXCTestSkipsStartupSequence() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        #expect(virtualDisplay.loadPersistedConfigsCallCount == 0)
        #expect(virtualDisplay.restoreDesiredVirtualDisplaysCallCount == 0)
        #expect(sharing.startWebServiceCallCount == 0)
        #expect(sut.virtualDisplay.displayConfigs.isEmpty)
    }

    @Test func initNormalModeLoadsPersistedDataAndStartsWebService() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()

        let fixtureConfig = VirtualDisplayConfig(
            displayName: "Fixture",
            serialNum: 1,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [fixtureConfig]

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isRunningUnderXCTestOverride: false
        )

        let didStartWebService = await waitUntil {
            sharing.startWebServiceCallCount == 1
        }

        #expect(didStartWebService)
        #expect(virtualDisplay.loadPersistedConfigsCallCount == 1)
        #expect(virtualDisplay.restoreDesiredVirtualDisplaysCallCount == 1)
        #expect(sut.virtualDisplay.displayConfigs.count == 1)
        #expect(sut.virtualDisplay.displayConfigs.first?.id == fixtureConfig.id)
        #expect(sut.virtualDisplay.displayConfigs.first?.serialNum == fixtureConfig.serialNum)
    }

    @Test func controllerExposesConfigStoreLoadFailureState() {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()
        virtualDisplay.configStoreState = .loadFailed(
            error: .unsupportedSchemaVersion(expected: 3, actual: 2),
            diagnostics: .init(
                primaryStoreURL: URL(fileURLWithPath: "/tmp/virtual-displays.json"),
                legacyContainerStoreURL: URL(fileURLWithPath: "/tmp/legacy.json"),
                legacyContainerFileExists: true,
                isTestIsolatedPath: true
            )
        )

        let env = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        env.virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        #expect(env.virtualDisplay.configStorePresentation.hasLoadFailure)
        #expect(env.virtualDisplay.configStorePresentation.loadErrorMessage?.contains("Reset") == true)
        #expect(env.virtualDisplay.configStorePresentation.diagnosticsSummary?.contains("primary=/tmp/virtual-displays.json") == true)
    }

    @Test func rebuildFromSavedConfigDoesNotApplyModesAgainAfterRebuild() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()

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

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isRunningUnderXCTestOverride: true
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

    @Test func startRebuildStopsDependentSharingAndMonitoringForRuntimeDisplay() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()

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

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        sut.virtualDisplay.startRebuildFromSavedConfig(configId: config.id)

        let rebuildTriggered = await waitUntil {
            virtualDisplay.rebuildVirtualDisplayCallCount == 1
        }

        #expect(rebuildTriggered)
        #expect(sharing.stopSharingCallCount == 1)
        #expect(capture.removeByDisplayCallCount == 1)
        #expect(capture.removedDisplayIDs == [displayID])
    }

    @Test func startRebuildIgnoresConcurrentDuplicateRequests() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()
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

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        sut.virtualDisplay.startRebuildFromSavedConfig(configId: config.id)
        sut.virtualDisplay.startRebuildFromSavedConfig(configId: config.id)

        let onlyOnceTriggered = await waitUntil {
            virtualDisplay.rebuildVirtualDisplayCallCount == 1
        }
        #expect(onlyOnceTriggered)

        let settled = await waitUntil {
            !sut.virtualDisplay.isRebuilding(configId: config.id)
        }
        #expect(settled)
    }

    @Test func rebuildFailureRetryAndAppliedBadgeLifecycle() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()

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

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            appliedBadgeDisplayDurationNanoseconds: 50_000_000,
            isRunningUnderXCTestOverride: true
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

        let successCleared = await waitUntil(timeoutNanoseconds: 500_000_000) {
            !sut.virtualDisplay.hasRecentApplySuccess(configId: config.id)
        }
        #expect(successCleared)
    }

    @Test func moveDisplayConfigTriggersMainDisplayPolicyReconcile() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()
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

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        let moved = sut.virtualDisplay.moveDisplayConfig(
            virtualDisplay.currentDisplayConfigs[1].id,
            direction: .up
        )
        #expect(moved)

        let reconciled = await waitUntil {
            virtualDisplay.reconcileMainDisplayPolicyIfNeededCallCount == 1
        }
        #expect(reconciled)
    }

    @Test func moveDisplayConfigSkipsReconcileWhenFirstEnabledConfigDoesNotChange() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()
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

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )
        sut.virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        let moved = sut.virtualDisplay.moveDisplayConfig(configC.id, direction: .up)
        #expect(moved)

        await drainMainActorTasks()
        #expect(virtualDisplay.reconcileMainDisplayPolicyIfNeededCallCount == 0)
    }

    @Test func setPrimaryVirtualDisplayByReorderingMovesTargetToFirstEnabledAndReconciles() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()
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

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        let changed = sut.virtualDisplay.setPrimaryVirtualDisplayByReordering(configB.id)
        #expect(changed)
        #expect(virtualDisplay.currentDisplayConfigs.map(\.id) == [disabled.id, configB.id, configA.id])
        #expect(virtualDisplay.moveConfigToFirstEnabledPositionCallCount == 1)
        #expect(virtualDisplay.moveConfigToFirstEnabledPositionIDs == [configB.id])

        let reconciled = await waitUntil {
            virtualDisplay.reconcileMainDisplayPolicyIfNeededCallCount == 1
        }
        #expect(reconciled)
    }

    @Test func setPrimaryVirtualDisplayByReorderingNoOpsWhenAlreadyFirstEnabled() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()
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

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        let changed = sut.virtualDisplay.setPrimaryVirtualDisplayByReordering(configA.id)
        #expect(changed == false)
        #expect(virtualDisplay.moveConfigToFirstEnabledPositionCallCount == 1)

        await drainMainActorTasks()
        #expect(virtualDisplay.reconcileMainDisplayPolicyIfNeededCallCount == 0)
    }

    @Test func setPrimaryVirtualDisplayByReorderingNoOpsWhenTargetDisabled() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()
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

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        let changed = sut.virtualDisplay.setPrimaryVirtualDisplayByReordering(disabled.id)
        #expect(changed == false)
        #expect(virtualDisplay.moveConfigToFirstEnabledPositionCallCount == 1)
        #expect(virtualDisplay.currentDisplayConfigs.map(\.id) == [disabled.id, enabled.id])

        await drainMainActorTasks()
        #expect(virtualDisplay.reconcileMainDisplayPolicyIfNeededCallCount == 0)
    }

    @Test func sharingFacadeMethodsDelegateAndExposeState() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()

        let displayID: CGDirectDisplayID = 7101
        let target = ShareTarget.id(99)
        sharing.startResult = true
        sharing.activeStreamClientCount = 3
        sharing.activeSharingDisplayIDs = [displayID]
        sharing.hasAnyActiveSharing = true
        sharing.shareIDByDisplayID[displayID] = 99
        sharing.shareTargetByDisplayID[displayID] = target
        sharing.streamClientCountsByTarget[target] = 3

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        let started = await sut.sharing.startWebService()
        #expect(started)
        #expect(sut.sharing.isWebServiceRunning)
        #expect(sut.sharing.isSharing)
        #expect(sut.sharing.isDisplaySharing(displayID: displayID))
        #expect(sut.sharing.sharePagePath(for: displayID) == "/display/99")

        sut.sharing.refreshSharingClientCount()
        #expect(sut.sharing.sharingClientCount == 3)
        #expect(sut.sharing.sharingClientCounts[displayID] == 3)

        // Uses facade path that should fail early when service is down.
        sut.sharing.stopWebService()
        let shareURLResult = sut.sharing.sharePageURLResolution(for: displayID)
        #expect(shareURLResult == .failure(.serviceNotRunning))
    }

    @Test func virtualDisplayFacadeResetDelegatesToService() {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()

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

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        let removed = sut.virtualDisplay.resetVirtualDisplayData()
        #expect(removed == 1)
        #expect(virtualDisplay.resetAllVirtualDisplayDataCallCount == 1)
    }
}
