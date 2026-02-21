import Testing
import CoreGraphics
@testable import VoidDisplay

@MainActor
struct AppHelperTests {

    @Test func initPreviewModeSkipsStartupSequence() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()

        _ = AppHelper(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isUITestModeOverride: false,
            isRunningUnderXCTestOverride: false
        )

        #expect(virtualDisplay.loadPersistedConfigsCallCount == 0)
        #expect(virtualDisplay.restoreDesiredVirtualDisplaysCallCount == 0)
        #expect(sharing.startWebServiceCallCount == 0)
    }

    @Test func initUITestModeAppliesFixtureAndSkipsServiceBoot() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()

        let sut = AppHelper(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isUITestModeOverride: true,
            isRunningUnderXCTestOverride: false
        )

        #expect(virtualDisplay.loadPersistedConfigsCallCount == 0)
        #expect(virtualDisplay.restoreDesiredVirtualDisplaysCallCount == 0)
        #expect(sharing.startWebServiceCallCount == 0)
        #expect(sut.displayConfigs.count == 2)
        #expect(sut.runningConfigIds.count == 1)
    }

    @Test func initRunningUnderXCTestSkipsStartupSequence() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayService()

        let sut = AppHelper(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isUITestModeOverride: false,
            isRunningUnderXCTestOverride: true
        )

        #expect(virtualDisplay.loadPersistedConfigsCallCount == 0)
        #expect(virtualDisplay.restoreDesiredVirtualDisplaysCallCount == 0)
        #expect(sharing.startWebServiceCallCount == 0)
        #expect(sut.displayConfigs.isEmpty)
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

        let sut = AppHelper(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isUITestModeOverride: false,
            isRunningUnderXCTestOverride: false
        )

        let didStartWebService = await waitUntil {
            sharing.startWebServiceCallCount == 1
        }

        #expect(didStartWebService)
        #expect(virtualDisplay.loadPersistedConfigsCallCount == 1)
        #expect(virtualDisplay.restoreDesiredVirtualDisplaysCallCount == 1)
        #expect(sut.displayConfigs.count == 1)
        #expect(sut.displayConfigs.first?.id == fixtureConfig.id)
        #expect(sut.displayConfigs.first?.serialNum == fixtureConfig.serialNum)
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

        let sut = AppHelper(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isUITestModeOverride: false,
            isRunningUnderXCTestOverride: true
        )

        sut.startRebuildFromSavedConfig(configId: config.id)

        let rebuildTriggered = await waitUntil {
            virtualDisplay.rebuildVirtualDisplayCallCount == 1
        }
        let rebuildPresentationSettled = await waitUntil {
            !sut.isRebuilding(configId: config.id)
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

        let sut = AppHelper(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayService: virtualDisplay,
            isUITestModeOverride: false,
            isRunningUnderXCTestOverride: true
        )

        sut.startRebuildFromSavedConfig(configId: config.id)

        let rebuildTriggered = await waitUntil {
            virtualDisplay.rebuildVirtualDisplayCallCount == 1
        }

        #expect(rebuildTriggered)
        #expect(sharing.stopSharingCallCount == 1)
        #expect(capture.removeByDisplayCallCount == 1)
        #expect(capture.removedDisplayIDs == [displayID])
    }
}
