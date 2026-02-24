import Testing
import CoreGraphics
@testable import VoidDisplay

@MainActor
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
            name: "Fixture",
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

    @Test func rebuildFromSavedConfigDoesNotApplyModesAgainAfterRebuild() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()

        let config = VirtualDisplayConfig(
            name: "Running",
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
            name: "Main Candidate",
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
            name: "Concurrent",
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
            name: "Retry",
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
                name: "Cleanup",
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
