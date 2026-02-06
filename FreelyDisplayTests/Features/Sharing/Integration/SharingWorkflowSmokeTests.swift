import Testing
@testable import FreelyDisplay

struct SharingWorkflowSmokeTests {

    @MainActor @Test func sharingServiceStartStopWorkflowSmoke() {
        let controller = MockWebServiceController()
        let service = SharingService(webServiceController: controller)

        #expect(service.isWebServiceRunning == false)
        #expect(service.isSharing == false)

        let started = service.startWebService()
        #expect(started)
        #expect(service.isWebServiceRunning)
        #expect(controller.startCallCount == 1)
        #expect(controller.capturedIsSharingProvider?() == false)
        #expect(controller.capturedFrameProvider?() == nil)

        // Stopping sharing with no active capture should still be safe and disconnect clients.
        service.stopSharing()
        #expect(service.isSharing == false)
        #expect(service.currentStream == nil)
        #expect(service.currentCapture == nil)
        #expect(service.currentDelegate == nil)
        #expect(controller.disconnectCallCount == 1)

        service.stopWebService()
        #expect(service.isWebServiceRunning == false)
        #expect(controller.stopCallCount == 1)
        #expect(controller.disconnectCallCount == 2)

        let startedAgain = service.startWebService()
        #expect(startedAgain)
        #expect(service.isWebServiceRunning)
        #expect(controller.startCallCount == 2)
    }
}
