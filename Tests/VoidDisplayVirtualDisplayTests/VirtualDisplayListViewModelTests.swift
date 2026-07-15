@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayVirtualDisplayTestingSupport
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import CoreGraphics
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct VirtualDisplayListViewModelTests {

    @Test func requestDeleteAndConfirmDeletesConfigThroughController() async {
        let config = sampleConfig(serial: 101)
        let mockService = MockVirtualDisplayFacade()
        mockService.currentDisplayConfigs = [config]
        let controller = makeController(virtualDisplayFacade: mockService)
        controller.configureDeleteExecutor { configID in
            let result = try mockService.deleteDisplayCommand(configID)
            return VirtualDisplayDeleteTransactionResult(
                transactionID: UUID(),
                status: .completed,
                configID: result.configID,
                virtualDisplayCommandSucceeded: result.virtualDisplayCommandOutcome == .succeeded
            )
        }

        let sut = VirtualDisplayListViewModel(controller: controller)

        sut.requestDelete(config)
        #expect(sut.showDeleteConfirm)
        #expect(sut.deleteCandidate?.id == config.id)

        sut.confirmDelete()
        let finished = await waitUntil { sut.showDeleteConfirm == false && sut.deleteCandidate == nil }

        #expect(finished)
        #expect(mockService.destroyDisplayByConfigCallCount == 1)
        #expect(mockService.destroyedConfigIDs == [config.id])
    }

    @Test func confirmDeleteShowsErrorWhenDestroyFails() async {
        let config = sampleConfig(serial: 102)
        let mockService = MockVirtualDisplayFacade()
        mockService.currentDisplayConfigs = [config]
        mockService.destroyDisplayError = NSError(domain: "VirtualDisplayListViewModelTests", code: 12)
        let controller = makeController(virtualDisplayFacade: mockService)
        controller.configureDeleteExecutor { configID in
            let result = try mockService.deleteDisplayCommand(configID)
            return VirtualDisplayDeleteTransactionResult(
                transactionID: UUID(),
                status: .completed,
                configID: result.configID,
                virtualDisplayCommandSucceeded: result.virtualDisplayCommandOutcome == .succeeded
            )
        }

        let sut = VirtualDisplayListViewModel(controller: controller)

        sut.requestDelete(config)
        sut.confirmDelete()
        let finished = await waitUntil { sut.userFacingAlert != nil }

        #expect(finished)
        #expect(sut.showDeleteConfirm)
        #expect(sut.deleteCandidate?.id == config.id)
        #expect(sut.userFacingAlert != nil)
        #expect(sut.userFacingAlert?.message.isEmpty == false)
        #expect(mockService.destroyDisplayByConfigCallCount == 1)
        #expect(mockService.destroyedConfigIDs == [config.id])
    }

    @Test func confirmDeleteRecoveryFailureClosesConfirmation() async {
        let config = sampleConfig(serial: 103)
        let sut = VirtualDisplayListViewModel(
            dependencies: .test(
                deleteVirtualDisplay: { _ in }
            )
        )

        sut.requestDelete(config)
        sut.confirmDelete()
        let finished = await waitUntil { sut.showDeleteConfirm == false && sut.deleteCandidate == nil }

        #expect(finished)
        #expect(sut.userFacingAlert == nil)
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

    @Test func toggleDisplayStateEnablesWhenDesiredStateIsDisabled() async {
        let config = sampleConfig(serial: 201)
        let gate = AsyncGate()
        var requests: [(UUID, Bool)] = []
        let sut = VirtualDisplayListViewModel(
            dependencies: .test(
                setVirtualDisplayDesiredEnabled: { configID, enabled in
                    requests.append((configID, enabled))
                    await gate.wait()
                }
            )
        )

        sut.toggleDisplayState(config)
        let started = await waitUntil {
            requests.map(\.0) == [config.id] && sut.togglingConfigIds == [config.id]
        }
        gate.open()
        let finished = await waitUntil { sut.togglingConfigIds.isEmpty }

        #expect(started)
        #expect(finished)
        #expect(requests.map(\.1) == [true])
        #expect(sut.userFacingAlert == nil)
    }

    @Test func toggleDisplayStateDisablesWhenDesiredStateIsEnabledButDisplayIsStopped() async {
        var config = sampleConfig(serial: 202)
        config.desiredEnabled = true
        var requests: [(UUID, Bool)] = []
        let sut = VirtualDisplayListViewModel(
            dependencies: .test(
                setVirtualDisplayDesiredEnabled: { configID, enabled in
                    requests.append((configID, enabled))
                }
            )
        )

        sut.toggleDisplayState(config)
        let finished = await waitUntil { sut.togglingConfigIds.isEmpty && !requests.isEmpty }

        #expect(finished)
        #expect(requests.map(\.0) == [config.id])
        #expect(requests.map(\.1) == [false])
        #expect(sut.userFacingAlert == nil)
    }

    @Test func toggleDisplayStateShowsErrorWhenDisableFails() async {
        var config = sampleConfig(serial: 301)
        config.desiredEnabled = true
        var requests: [(UUID, Bool)] = []
        let sut = VirtualDisplayListViewModel(
            dependencies: .test(
                setVirtualDisplayDesiredEnabled: { configID, enabled in
                    requests.append((configID, enabled))
                    throw NSError(domain: "VirtualDisplayListViewModelTests", code: 9)
                }
            )
        )

        sut.toggleDisplayState(config)
        let finished = await waitUntil {
            sut.userFacingAlert != nil && sut.togglingConfigIds.isEmpty
        }

        #expect(finished)
        #expect(requests.map(\.0) == [config.id])
        #expect(requests.map(\.1) == [false])
        #expect(sut.userFacingAlert?.message.isEmpty == false)
    }

    @Test func toggleDisplayStateShowsErrorWhenEnableFails() async {
        let config = sampleConfig(serial: 302)
        let sut = VirtualDisplayListViewModel(
            dependencies: .test(
                setVirtualDisplayDesiredEnabled: { _, _ in
                    throw NSError(domain: "VirtualDisplayListViewModelTests", code: 10)
                }
            )
        )

        sut.toggleDisplayState(config)
        let finished = await waitUntil {
            sut.userFacingAlert != nil && sut.togglingConfigIds.isEmpty
        }

        #expect(finished)
        #expect(sut.userFacingAlert?.title == "Enable Failed")
        #expect(sut.userFacingAlert?.message.isEmpty == false)
    }

    @Test func isPrimaryDisplayUsesRuntimeDisplayIDHintWhenRuntimeObjectIsUnavailable() {
        let config = sampleConfig(serial: 401)
        let mockService = MockVirtualDisplayFacade()
        mockService.currentDisplayConfigs = [config]
        mockService.currentRunningConfigIds = [config.id]
        mockService.runtimeDisplayIDByConfigId[config.id] = CGMainDisplayID()
        let controller = makeController(virtualDisplayFacade: mockService)

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
            appliedBadgeDisplayDuration: .seconds(0.1)
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

private extension VirtualDisplayListViewModel.Dependencies {
    static func test(
        deleteVirtualDisplay: @escaping @MainActor (UUID) async throws -> Void = { _ in },
        setVirtualDisplayDesiredEnabled: @escaping @MainActor (UUID, Bool) async throws -> Void = { _, _ in }
    ) -> Self {
        Self(
            restoreFailures: { [] },
            clearRestoreFailures: {},
            deleteVirtualDisplay: deleteVirtualDisplay,
            runtimeDisplayID: { _ in nil },
            isRebuilding: { _ in false },
            setVirtualDisplayDesiredEnabled: setVirtualDisplayDesiredEnabled
        )
    }
}

@MainActor
private final class AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
