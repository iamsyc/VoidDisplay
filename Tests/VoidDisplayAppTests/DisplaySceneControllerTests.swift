@testable import VoidDisplayApp
@testable import VoidDisplayRuntime
@testable import VoidDisplayTestingSupport
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayVirtualDisplayTestingSupport
import Foundation
import Testing

@MainActor
struct DisplaySceneControllerTests {
    @Test func repeatedApplicationPreservesTheAcceptedBatchResult() async throws {
        let fixture = try SceneStoreFixture()
        defer { fixture.remove() }
        let facade = MockVirtualDisplayFacade()
        let config = VirtualDisplayConfig(displayName: "Demo", serialNum: 9901,
            physicalWidth: 300, physicalHeight: 190,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)], desiredEnabled: false)
        facade.currentDisplayConfigs = [config]
        facade.enableRuntimeDisplayError = NSError(domain: "injected", code: 1)
        let environment = AppBootstrap.makeEnvironment(preview: true,
            capturePreviewService: MockCapturePreviewService(), sharingService: MockSharingService(),
            virtualDisplayFacade: facade, startupPlan: .skipAll, isRunningUnderXCTestOverride: true)
        let controller = DisplaySceneController(store: fixture.store, runtime: environment.displayRuntime, virtualDisplay: environment.virtualDisplay)
        let accepted = try environment.displayRuntime.prepareVirtualDisplayEnabledSet(targetConfigIDs: [config.id])
        let duplicate = try environment.displayRuntime.prepareVirtualDisplayEnabledSet(targetConfigIDs: [config.id])
        controller.apply(accepted)
        controller.apply(duplicate)
        #expect(await waitUntil {
            !controller.isBusy && environment.displayRuntime.makeSnapshot().transactions.recentTransactions.contains { $0.id == accepted.operationID }
        })
        #expect(controller.lastResult?.operationID == accepted.operationID)
        #expect(controller.lastResult?.status == .failed)
        #expect(controller.lastResult?.previousConfigIDs == [])
        #expect(controller.lastResult?.steps.count == 1)
        #expect(facade.enableRuntimeDisplayCallCount == 1)
    }

    @Test func failedApplyPublishesChangedIntentToTheSharedConfigurationCache() async throws {
        let fixture = try SceneStoreFixture()
        defer { fixture.remove() }
        let facade = MockVirtualDisplayFacade()
        let config = VirtualDisplayConfig(displayName: "Demo", serialNum: 9901,
            physicalWidth: 300, physicalHeight: 190,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)], desiredEnabled: false)
        facade.currentDisplayConfigs = [config]
        facade.enableRuntimeDisplayError = NSError(domain: "injected", code: 1)
        let environment = AppBootstrap.makeEnvironment(preview: true,
            capturePreviewService: MockCapturePreviewService(), sharingService: MockSharingService(),
            virtualDisplayFacade: facade, startupPlan: .skipAll, isRunningUnderXCTestOverride: true)
        let controller = DisplaySceneController(store: fixture.store, runtime: environment.displayRuntime, virtualDisplay: environment.virtualDisplay)
        controller.apply(try environment.displayRuntime.prepareVirtualDisplayEnabledSet(targetConfigIDs: [config.id]))
        #expect(await waitUntil { controller.lastResult != nil })
        #expect(controller.lastResult?.status == .failed)
        #expect(!controller.isBusy)
        #expect(environment.virtualDisplay.getConfig(config.id)?.desiredEnabled == true)
        #expect(environment.virtualDisplay.getConfig(config.id) == facade.currentDisplayConfigs.first)
        #expect(!controller.currentCombinationIsSettled)
        #expect(facade.setDesiredEnabledCallCount == 1)
        #expect(facade.enableRuntimeDisplayCallCount == 1)
    }

    @Test func historicalFailureDoesNotPreventMatchingAndRepeatedSelectionDoesNothing() throws {
        let fixture = try SceneStoreFixture()
        defer { fixture.remove() }
        let facade = MockVirtualDisplayFacade()
        let config = VirtualDisplayConfig(displayName: "Demo", serialNum: 9901,
            physicalWidth: 300, physicalHeight: 190,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)], desiredEnabled: true)
        facade.currentDisplayConfigs = [config]
        facade.currentRunningConfigIds = [config.id]
        facade.runtimeDisplayIDByConfigId = [config.id: 9901]
        let environment = AppBootstrap.makeEnvironment(preview: true,
            capturePreviewService: MockCapturePreviewService(), sharingService: MockSharingService(),
            virtualDisplayFacade: facade, startupPlan: .skipAll, isRunningUnderXCTestOverride: true)
        let controller = DisplaySceneController(store: fixture.store, runtime: environment.displayRuntime, virtualDisplay: environment.virtualDisplay)
        try fixture.store.save(name: "Demo", enabledConfigIDs: [config.id])
        environment.displayRuntime.recordFailure(code: "historical_failure")
        #expect(controller.matchedScene?.name == "Demo")
        let scene = try #require(controller.matchedScene)
        #expect(controller.select(scene) == nil)
        #expect(environment.displayRuntime.makeSnapshot().transactions.activeTransactions.isEmpty)
        #expect(environment.displayRuntime.makeSnapshot().latestFailure?.code == "historical_failure")
        facade.currentRunningConfigIds = []
        facade.runtimeDisplayIDByConfigId = [:]
        environment.virtualDisplay.refreshVirtualDisplayState()
        #expect(controller.matchedScene == nil)
        facade.currentDisplayConfigs = []
        environment.virtualDisplay.refreshVirtualDisplayState()
        #expect(controller.hasMissingReferences(scene))
        #expect(controller.select(scene) == nil)
        #expect(controller.errorMessage != nil)
        #expect(fixture.store.scenes.first?.enabledConfigIDs == [config.id])
        let diagnostic = DisplaySceneSnapshotProvider(controller: controller).makeSnapshot()
        let data = try JSONEncoder().encode(diagnostic)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["sceneCount", "invalidReferenceCount"])
        #expect(diagnostic.sceneCount == 1)
        #expect(diagnostic.invalidReferenceCount == 1)
        #expect(!String(decoding: data, as: UTF8.self).contains(scene.name))
        #expect(!String(decoding: data, as: UTF8.self).contains(config.id.uuidString))
    }
}
