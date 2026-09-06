@testable import VoidDisplayApp
@testable import VoidDisplayFoundation
@testable import VoidDisplaySharing
@testable import VoidDisplayTestingSupport
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayVirtualDisplayTestingSupport
import Foundation
import Testing

@MainActor
struct HomeVirtualDisplaySurfaceControllerTests {
    @Test
    func sharingPortDraftValidatesBeforePersisting() {
        let (controller, environment) = makeController()
        let originalPort = environment.sharing.preferredWebServicePort

        controller.updateSharingPortDraft("70000")
        controller.applySharingPortDraft()

        #expect(controller.sharingPortErrorMessage != nil)
        #expect(environment.sharing.preferredWebServicePort == originalPort)

        controller.updateSharingPortDraft("18082")
        controller.applySharingPortDraft()

        #expect(controller.sharingPortInput == "18082")
        #expect(controller.sharingPortErrorMessage == nil)
        #expect(environment.sharing.preferredWebServicePort == 18082)
    }

    @Test
    func externalPortChangeDoesNotReplaceInvalidDraft() {
        let (controller, environment) = makeController()
        let originalPort = environment.sharing.preferredWebServicePort

        controller.updateSharingPortDraft("70000")
        controller.applySharingPortDraft()
        environment.sharing.savePreferredWebServicePort(18083)
        controller.handlePreferredSharingPortChanged(from: originalPort, to: 18083)

        #expect(controller.sharingPortInput == "70000")
        #expect(controller.sharingPortErrorMessage != nil)
    }

    @Test
    func startingSharingRejectsInvalidPortBeforeStartingService() async throws {
        let service = MockSharingService()
        let facade = makeFacade()
        let (controller, environment) = makeController(sharingService: service, virtualDisplayFacade: facade)
        let item = try #require(controller.presentation.items.first)
        controller.updateSharingPortDraft("70000")

        controller.perform(.webView, for: item, openPreviewWindow: { _ in }, openSharePage: { _ in }, editConfig: { _ in })

        #expect(await waitUntil { controller.sharingPortErrorMessage != nil })
        #expect(service.startWebServiceCallCount == 0)
        #expect(service.startSharingCallCount == 0)
        #expect(environment.displayRuntime.currentConsumerLeaseSnapshot().isEmpty)
    }

    @Test
    func serviceStartFailureSurfacesErrorWithoutCreatingSharingLease() async throws {
        let service = MockSharingService()
        let failure = WebServiceStartFailure.listenerFailed(port: 18_085, message: "injected bind failure")
        service.startResult = .failed(failure)
        let (controller, environment) = makeController(sharingService: service, virtualDisplayFacade: makeFacade())
        let item = try #require(controller.presentation.items.first)
        controller.updateSharingPortDraft("18085")

        controller.perform(.webView, for: item, openPreviewWindow: { _ in }, openSharePage: { _ in }, editConfig: { _ in })

        #expect(await waitUntil { controller.actionAlert != nil })
        #expect(controller.actionAlert?.message == failure.userMessage)
        #expect(service.startWebServiceCallCount == 1)
        #expect(service.startSharingCallCount == 0)
        #expect(environment.displayRuntime.currentConsumerLeaseSnapshot().isEmpty)
        #expect(controller.isWebServiceRunning == false)
        controller.dismissActionAlert()
        #expect(controller.actionAlert == nil)
    }

    @Test(arguments: [HomeVirtualDisplayItemAction.moveUp, .moveDown])
    func reorderFailurePreservesConfigsAndExposesPersistenceError(action: HomeVirtualDisplayItemAction) throws {
        let facade = makeFacade()
        let originalConfigs = facade.currentDisplayConfigs
        facade.moveConfigError = NSError(domain: "surface-tests", code: 1)
        let (controller, environment) = makeController(virtualDisplayFacade: facade)
        let item: HomeVirtualDisplayItemPresentation
        if case .moveUp = action {
            item = try #require(controller.presentation.items.last)
        } else {
            item = try #require(controller.presentation.items.first)
        }

        controller.perform(action, for: item, openPreviewWindow: { _ in }, openSharePage: { _ in }, editConfig: { _ in })

        #expect(environment.virtualDisplay.persistenceAlert?.title == String(localized: "Save Failed"))
        #expect(environment.virtualDisplay.displayConfigs == originalConfigs)
        #expect(facade.destroyDisplayByConfigCallCount == 0)
        #expect(facade.reconcileMainDisplayPolicyIfNeededCallCount == 0)
    }

    @Test
    func failedResetKeepsConfigsAndAllowsRetry() {
        let facade = makeFacade()
        let originalConfigs = facade.currentDisplayConfigs
        facade.resetAllVirtualDisplayDataError = NSError(domain: "surface-tests", code: 2)
        let (controller, environment) = makeController(virtualDisplayFacade: facade)

        controller.resetConfigStore()

        #expect(environment.virtualDisplay.persistenceAlert?.title == String(localized: "Reset Failed"))
        #expect(environment.virtualDisplay.displayConfigs == originalConfigs)
        facade.resetAllVirtualDisplayDataError = nil
        controller.resetConfigStore()

        #expect(facade.resetAllVirtualDisplayDataCallCount == 2)
        #expect(environment.virtualDisplay.displayConfigs.isEmpty)
        #expect(environment.virtualDisplay.persistenceAlert == nil)
    }

    private func makeFacade() -> MockVirtualDisplayFacade {
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [UInt32(9_904), 9_905].map { serial in
            VirtualDisplayConfig(
                displayName: "Surface test", serialNum: serial,
                physicalWidth: 300, physicalHeight: 190,
                modes: [.init(width: 1_920, height: 1_080, refreshRate: 60, enableHiDPI: false)],
                desiredEnabled: false
            )
        }
        facade.runtimeDisplayIDByConfigId = Dictionary(uniqueKeysWithValues: facade.currentDisplayConfigs.map { ($0.id, $0.serialNum) })
        return facade
    }

    private func makeController(
        sharingService: MockSharingService = MockSharingService(),
        virtualDisplayFacade: MockVirtualDisplayFacade = MockVirtualDisplayFacade()
    ) -> (
        HomeVirtualDisplaySurfaceController,
        AppEnvironment
    ) {
        let environment = AppBootstrap.makeEnvironment(
            preview: true,
            capturePreviewService: MockCapturePreviewService(),
            sharingService: sharingService,
            virtualDisplayFacade: virtualDisplayFacade,
            startupPlan: .init(shouldRestoreVirtualDisplays: false),
            isRunningUnderXCTestOverride: true
        )
        let controller = HomeVirtualDisplaySurfaceController(
            capture: environment.capture,
            sharing: environment.sharing,
            virtualDisplay: environment.virtualDisplay,
            capturePerformancePreferences: environment.capturePerformancePreferences,
            displayRuntime: environment.displayRuntime,
            sharingAdapter: environment.sharingAdapter
        )
        return (controller, environment)
    }
}
