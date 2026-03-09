import Foundation
import Testing
@testable import VoidDisplay

@MainActor
@Suite(.serialized)
struct VirtualDisplayListViewModelTests {

    @Test func requestDeleteAndConfirmDeletesConfigThroughController() {
        let config = sampleConfig(serial: 101)
        let mockService = MockVirtualDisplayFacade()
        mockService.currentDisplayConfigs = [config]
        let env = makeEnvironment(virtualDisplayFacade: mockService)
        env.virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        let sut = VirtualDisplayListViewModel(controller: env.virtualDisplay)

        sut.requestDelete(config)
        #expect(sut.showDeleteConfirm)
        #expect(sut.deleteCandidate?.id == config.id)

        sut.confirmDelete()

        #expect(sut.showDeleteConfirm == false)
        #expect(sut.deleteCandidate == nil)
        #expect(mockService.destroyDisplayByConfigCallCount == 1)
        #expect(mockService.destroyedConfigIDs == [config.id])
    }

    @Test func confirmDeleteShowsErrorWhenDestroyFails() {
        let config = sampleConfig(serial: 102)
        let mockService = MockVirtualDisplayFacade()
        mockService.currentDisplayConfigs = [config]
        mockService.destroyDisplayError = NSError(domain: "VirtualDisplayListViewModelTests", code: 12)
        let env = makeEnvironment(virtualDisplayFacade: mockService)
        env.virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        let sut = VirtualDisplayListViewModel(controller: env.virtualDisplay)

        sut.requestDelete(config)
        sut.confirmDelete()

        #expect(sut.showDeleteConfirm)
        #expect(sut.deleteCandidate?.id == config.id)
        #expect(sut.showError)
        #expect(sut.errorMessage.isEmpty == false)
        #expect(mockService.destroyDisplayByConfigCallCount == 1)
        #expect(mockService.destroyedConfigIDs == [config.id])
    }

    @Test func acknowledgeRestoreFailuresCallsControllerClear() {
        let mockService = MockVirtualDisplayFacade()
        let env = makeEnvironment(virtualDisplayFacade: mockService)
        let sut = VirtualDisplayListViewModel(controller: env.virtualDisplay)

        sut.handleRestoreFailuresChanged([
            .init(id: UUID(), name: "VD", serialNum: 11, message: "Failed")
        ])
        #expect(sut.showRestoreFailureAlert)

        sut.acknowledgeRestoreFailures()
        #expect(mockService.clearRestoreFailuresCallCount == 1)
    }

    @Test func toggleDisplayStateEnablesWhenConfigIsStopped() async {
        let config = sampleConfig(serial: 201)
        let mockService = MockVirtualDisplayFacade()
        mockService.currentDisplayConfigs = [config]
        let env = makeEnvironment(virtualDisplayFacade: mockService)
        env.virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        let sut = VirtualDisplayListViewModel(controller: env.virtualDisplay)

        sut.toggleDisplayState(config)
        let finished = await waitUntil {
            mockService.enableDisplayCallCount == 1 && sut.togglingConfigIds.isEmpty
        }

        #expect(finished)
        #expect(mockService.enableDisplayConfigIDs == [config.id])
        #expect(sut.showError == false)
    }

    @Test func toggleDisplayStateShowsErrorWhenDisableFails() async {
        let config = sampleConfig(serial: 301)
        let mockService = MockVirtualDisplayFacade()
        mockService.currentDisplayConfigs = [config]
        mockService.currentRunningConfigIds = [config.id]
        mockService.disableDisplayByConfigError = NSError(domain: "VirtualDisplayListViewModelTests", code: 9)
        let env = makeEnvironment(virtualDisplayFacade: mockService)
        env.virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        let sut = VirtualDisplayListViewModel(controller: env.virtualDisplay)

        sut.toggleDisplayState(config)
        let finished = await waitUntil {
            sut.showError && sut.togglingConfigIds.isEmpty
        }

        #expect(finished)
        #expect(mockService.disableDisplayByConfigCallCount == 1)
        #expect(mockService.disableDisplayByConfigIDs == [config.id])
        #expect(sut.errorMessage.isEmpty == false)
    }

    @Test func isPrimaryDisplayUsesRuntimeDisplayIDHintWhenRuntimeObjectIsUnavailable() {
        let config = sampleConfig(serial: 401)
        let mockService = MockVirtualDisplayFacade()
        mockService.currentDisplayConfigs = [config]
        mockService.currentRunningConfigIds = [config.id]
        mockService.runtimeDisplayIDByConfigId[config.id] = CGMainDisplayID()
        let env = makeEnvironment(virtualDisplayFacade: mockService)
        env.virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        let sut = VirtualDisplayListViewModel(controller: env.virtualDisplay)

        #expect(sut.isPrimaryDisplay(configID: config.id))
    }

    @Test func initWithControllerSupportsPrimaryDisplayCheckWithoutPostAppearBinding() {
        let mockService = MockVirtualDisplayFacade()
        let config = sampleConfig(serial: 402)
        mockService.currentDisplayConfigs = [config]
        mockService.runtimeDisplayIDByConfigId[config.id] = CGMainDisplayID()
        let env = makeEnvironment(virtualDisplayFacade: mockService)
        let sut = VirtualDisplayListViewModel(controller: env.virtualDisplay)

        #expect(sut.isPrimaryDisplay(configID: config.id))
    }

    private func makeEnvironment(virtualDisplayFacade: MockVirtualDisplayFacade) -> AppEnvironment {
        AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: virtualDisplayFacade,
            isRunningUnderXCTestOverride: true
        )
    }

    private func sampleConfig(serial: UInt32) -> VirtualDisplayConfig {
        VirtualDisplayConfig(
            displayName: "Test \(serial)",
            serialNum: serial,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [
                .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
            ],
            desiredEnabled: false
        )
    }
}
