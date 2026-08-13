@testable import VoidDisplayApp
@testable import VoidDisplayVirtualDisplayTestingSupport
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

    private func makeController() -> (
        HomeVirtualDisplaySurfaceController,
        AppEnvironment
    ) {
        let environment = AppBootstrap.makeEnvironment(
            preview: true,
            capturePreviewService: MockCapturePreviewService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: MockVirtualDisplayFacade(),
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
