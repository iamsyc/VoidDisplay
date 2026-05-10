@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
@testable import VoidDisplaySharingTestingSupport
@testable import VoidDisplayTestingSupport
import CoreGraphics
import Foundation
import Testing

struct SharingWorkflowSmokeTests {

    @MainActor @Test func sharingServiceStartStopWorkflowSmoke() async {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let controller = MockWebServiceController()
        controller.startResult = .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort))
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("display-share-id-mappings.json", isDirectory: false)
        let idStore = DisplayShareIDStore(storeURL: storeURL)
        let coordinator = DisplaySharingCoordinator(idStore: idStore)
        let service = SharingService(
            webServiceController: controller,
            sharingCoordinator: coordinator
        )

        #expect(service.isWebServiceRunning == false)
        #expect(service.hasAnyActiveSharing == false)

        let started = await service.startWebService(requestedPort: requestedPort)
        #expect(started == .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)))
        #expect(service.isWebServiceRunning)
        #expect(controller.startCallCount == 1)
        #expect(controller.capturedTargetStateProvider?(.main) == .knownInactive)
        #expect(controller.capturedConcreteTargetResolver?(.main) == nil)
        #expect(controller.capturedSessionHubProvider?(.main) == nil)

        // Stopping sharing with no active capture should still be safe and disconnect clients.
        service.stopSharing(displayID: CGDirectDisplayID(7))
        #expect(service.hasAnyActiveSharing == false)
        #expect(controller.disconnectCallCount == 0)

        service.stopWebService()
        #expect(service.isWebServiceRunning == false)
        #expect(controller.stopCallCount == 1)
        #expect(controller.disconnectCallCount == 1)

        let startedAgain = await service.startWebService(requestedPort: requestedPort)
        #expect(startedAgain == .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)))
        #expect(service.isWebServiceRunning)
        #expect(controller.startCallCount == 2)
    }
}
