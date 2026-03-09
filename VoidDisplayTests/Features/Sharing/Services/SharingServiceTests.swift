import Foundation
import CoreGraphics
import Testing
@testable import VoidDisplay

struct SharingServiceTests {

    @MainActor @Test func startWebServiceDelegatesToControllerAndCapturesProviders() async {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let mock = MockWebServiceController()
        mock.startResult = .started(
            WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)
        )
        let sut = makeService(webServiceController: mock)

        let started = await sut.startWebService(requestedPort: requestedPort)

        #expect(started == .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)))
        #expect(mock.startCallCount == 1)
        #expect(sut.webServicePortValue == requestedPort)
        #expect(sut.isWebServiceRunning)
        #expect(mock.capturedTargetStateProvider?(.main) == .knownInactive)
        #expect(mock.capturedTargetStateProvider?(.id(123)) == .unknown)
        #expect(mock.capturedSessionHubProvider?(.main) == nil)
    }

    @MainActor @Test func startWebServiceReturnsFalseWhenControllerFails() async {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let mock = MockWebServiceController()
        mock.startResult = .failed(.portInUse(port: requestedPort))
        let sut = makeService(webServiceController: mock)

        let started = await sut.startWebService(requestedPort: requestedPort)

        #expect(started == .failed(.portInUse(port: requestedPort)))
        #expect(mock.startCallCount == 1)
        #expect(sut.isWebServiceRunning == false)
    }

    @MainActor @Test func stopSingleSharingKeepsConnectionManagementInTargetHub() {
        let mock = MockWebServiceController()
        let sut = makeService(webServiceController: mock)

        sut.stopSharing(displayID: CGDirectDisplayID(11))
        sut.stopSharing(displayID: CGDirectDisplayID(11))

        #expect(mock.disconnectCallCount == 0)
        #expect(sut.hasAnyActiveSharing == false)
    }

    @MainActor @Test func stopWebServiceStopsControllerAndDisconnectsAllStreamClients() {
        let mock = MockWebServiceController()
        let sut = makeService(webServiceController: mock)

        sut.stopWebService()

        #expect(mock.stopCallCount == 1)
        #expect(mock.disconnectCallCount == 1)
        #expect(sut.isWebServiceRunning == false)
    }

    @MainActor @Test func activeStreamClientCountReflectsControllerValue() {
        let mock = MockWebServiceController()
        mock.activeStreamClientCount = 3
        let sut = makeService(webServiceController: mock)

        #expect(sut.activeStreamClientCount == 3)
    }

    @MainActor @Test func forwardsWebServiceRunningStateCallbackFromController() {
        let mock = MockWebServiceController()
        let sut = makeService(webServiceController: mock)
        var receivedStates: [Bool] = []

        sut.onWebServiceRunningStateChanged = { isRunning in
            receivedStates.append(isRunning)
        }

        mock.onRunningStateChanged?(true)
        mock.onRunningStateChanged?(false)

        #expect(receivedStates == [true, false])
    }

    @MainActor @Test func forwardsWebServiceLifecycleStateCallbackFromController() {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let mock = MockWebServiceController()
        let sut = makeService(webServiceController: mock)
        var receivedStates: [WebServiceLifecycleState] = []

        sut.onWebServiceLifecycleStateChanged = { state in
            receivedStates.append(state)
        }

        let binding = WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)
        mock.onLifecycleStateChanged?(.starting(requestedPort: requestedPort))
        mock.onLifecycleStateChanged?(.running(binding))
        mock.onLifecycleStateChanged?(.stopped)

        #expect(receivedStates == [
            .starting(requestedPort: requestedPort),
            .running(binding),
            .stopped
        ])
    }

    @MainActor @Test func startAndStopEmitRunningStateChanges() async {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let mock = MockWebServiceController()
        mock.startResult = .started(
            WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)
        )
        let sut = makeService(webServiceController: mock)
        var receivedStates: [Bool] = []

        sut.onWebServiceRunningStateChanged = { isRunning in
            receivedStates.append(isRunning)
        }

        #expect(await sut.startWebService(requestedPort: requestedPort) == .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)))
        sut.stopWebService()

        #expect(receivedStates == [true, false])
    }

    @MainActor
    private func makeService(webServiceController: MockWebServiceController) -> SharingService {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("display-share-id-mappings.json", isDirectory: false)
        let idStore = DisplayShareIDStore(storeURL: storeURL)
        let coordinator = DisplaySharingCoordinator(idStore: idStore)
        return SharingService(
            webServiceController: webServiceController,
            sharingCoordinator: coordinator
        )
    }
}
