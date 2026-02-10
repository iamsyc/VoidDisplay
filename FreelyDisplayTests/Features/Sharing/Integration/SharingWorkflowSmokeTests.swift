import CoreGraphics
import Testing
@testable import FreelyDisplay

struct SharingWorkflowSmokeTests {

    @MainActor @Test func sharingServiceStartStopWorkflowSmoke() {
        let controller = MockWebServiceController()
        let service = SharingService(webServiceController: controller)

        #expect(service.isWebServiceRunning == false)
        #expect(service.hasAnyActiveSharing == false)

        let started = service.startWebService()
        #expect(started)
        #expect(service.isWebServiceRunning)
        #expect(controller.startCallCount == 1)
        #expect(controller.capturedTargetStateProvider?(.main) == .knownInactive)
        #expect(controller.capturedFrameProvider?(.main) == nil)

        // Stopping sharing with no active capture should still be safe and disconnect clients.
        service.stopSharing(displayID: CGDirectDisplayID(7))
        #expect(service.hasAnyActiveSharing == false)
        #expect(controller.disconnectCallCount == 0)

        service.stopWebService()
        #expect(service.isWebServiceRunning == false)
        #expect(controller.stopCallCount == 1)
        #expect(controller.disconnectCallCount == 1)

        let startedAgain = service.startWebService()
        #expect(startedAgain)
        #expect(service.isWebServiceRunning)
        #expect(controller.startCallCount == 2)
    }
}
