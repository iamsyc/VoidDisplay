import CoreGraphics
import Testing
@testable import VoidDisplay

struct SharingWorkflowSmokeTests {

    @MainActor @Test func sharingServiceStartStopWorkflowSmoke() async {
        let controller = MockWebServiceController()
        controller.startResult = .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081))
        let service = SharingService(webServiceController: controller)

        #expect(service.isWebServiceRunning == false)
        #expect(service.hasAnyActiveSharing == false)

        let started = await service.startWebService(requestedPort: 8081)
        #expect(started == .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081)))
        #expect(service.isWebServiceRunning)
        #expect(controller.startCallCount == 1)
        #expect(controller.capturedTargetStateProvider?(.main) == .knownInactive)
        #expect(controller.capturedLiveHubProvider?(.main) == nil)

        // Stopping sharing with no active capture should still be safe and disconnect clients.
        service.stopSharing(displayID: CGDirectDisplayID(7))
        #expect(service.hasAnyActiveSharing == false)
        #expect(controller.disconnectCallCount == 0)

        service.stopWebService()
        #expect(service.isWebServiceRunning == false)
        #expect(controller.stopCallCount == 1)
        #expect(controller.disconnectCallCount == 1)

        let startedAgain = await service.startWebService(requestedPort: 8081)
        #expect(startedAgain == .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081)))
        #expect(service.isWebServiceRunning)
        #expect(controller.startCallCount == 2)
    }
}
