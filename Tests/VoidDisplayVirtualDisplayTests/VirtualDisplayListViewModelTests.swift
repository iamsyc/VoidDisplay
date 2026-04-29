@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayFoundation
import CoreGraphics
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct VirtualDisplayListViewModelTests {

    @Test func requestDeleteAndConfirmDeletesConfigThroughController() {
        let config = sampleConfig(serial: 101)
        let mockService = MockVirtualDisplayFacade()
        mockService.currentDisplayConfigs = [config]
        let controller = makeController(virtualDisplayFacade: mockService)
        controller.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        let sut = VirtualDisplayListViewModel(controller: controller)

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
        let controller = makeController(virtualDisplayFacade: mockService)
        controller.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        let sut = VirtualDisplayListViewModel(controller: controller)

        sut.requestDelete(config)
        sut.confirmDelete()

        #expect(sut.showDeleteConfirm)
        #expect(sut.deleteCandidate?.id == config.id)
        #expect(sut.userFacingAlert != nil)
        #expect(sut.userFacingAlert?.message.isEmpty == false)
        #expect(mockService.destroyDisplayByConfigCallCount == 1)
        #expect(mockService.destroyedConfigIDs == [config.id])
    }

    @Test func acknowledgeRestoreFailuresCallsControllerClear() {
        let mockService = MockVirtualDisplayFacade()
        let controller = makeController(virtualDisplayFacade: mockService)
        let sut = VirtualDisplayListViewModel(controller: controller)

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
        let controller = makeController(virtualDisplayFacade: mockService)
        controller.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        let sut = VirtualDisplayListViewModel(controller: controller)

        sut.toggleDisplayState(config)
        let finished = await waitUntil {
            mockService.enableDisplayCallCount == 1 && sut.togglingConfigIds.isEmpty
        }

        #expect(finished)
        #expect(mockService.enableDisplayConfigIDs == [config.id])
        #expect(sut.userFacingAlert == nil)
    }

    @Test func toggleDisplayStateShowsErrorWhenDisableFails() async {
        let config = sampleConfig(serial: 301)
        let mockService = MockVirtualDisplayFacade()
        mockService.currentDisplayConfigs = [config]
        mockService.currentRunningConfigIds = [config.id]
        mockService.disableDisplayByConfigError = NSError(domain: "VirtualDisplayListViewModelTests", code: 9)
        let controller = makeController(virtualDisplayFacade: mockService)
        controller.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        let sut = VirtualDisplayListViewModel(controller: controller)

        sut.toggleDisplayState(config)
        let finished = await waitUntil {
            sut.userFacingAlert != nil && sut.togglingConfigIds.isEmpty
        }

        #expect(finished)
        #expect(mockService.disableDisplayByConfigCallCount == 1)
        #expect(mockService.disableDisplayByConfigIDs == [config.id])
        #expect(sut.userFacingAlert?.message.isEmpty == false)
    }

    @Test func isPrimaryDisplayUsesRuntimeDisplayIDHintWhenRuntimeObjectIsUnavailable() {
        let config = sampleConfig(serial: 401)
        let mockService = MockVirtualDisplayFacade()
        mockService.currentDisplayConfigs = [config]
        mockService.currentRunningConfigIds = [config.id]
        mockService.runtimeDisplayIDByConfigId[config.id] = CGMainDisplayID()
        let controller = makeController(virtualDisplayFacade: mockService)
        controller.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        let sut = VirtualDisplayListViewModel(controller: controller)

        #expect(sut.isPrimaryDisplay(configID: config.id))
    }

    @Test func initWithControllerSupportsPrimaryDisplayCheckWithoutPostAppearBinding() {
        let mockService = MockVirtualDisplayFacade()
        let config = sampleConfig(serial: 402)
        mockService.currentDisplayConfigs = [config]
        mockService.runtimeDisplayIDByConfigId[config.id] = CGMainDisplayID()
        let controller = makeController(virtualDisplayFacade: mockService)
        let sut = VirtualDisplayListViewModel(controller: controller)

        #expect(sut.isPrimaryDisplay(configID: config.id))
    }

    private func makeController(virtualDisplayFacade: MockVirtualDisplayFacade) -> VirtualDisplayController {
        VirtualDisplayController(
            virtualDisplayFacade: virtualDisplayFacade,
            appliedBadgeDisplayDuration: .seconds(0.1),
            stopDependentStreamsBeforeRebuild: { _ in }
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
