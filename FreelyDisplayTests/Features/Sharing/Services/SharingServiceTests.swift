import Foundation
import Testing
@testable import FreelyDisplay

struct SharingServiceTests {

    @MainActor @Test func startWebServiceDelegatesToControllerAndCapturesProviders() {
        let mock = MockWebServiceController()
        let sut = SharingService(webServiceController: mock)

        let started = sut.startWebService()

        #expect(started)
        #expect(mock.startCallCount == 1)
        #expect(sut.webServicePortValue == 9090)
        #expect(sut.isWebServiceRunning)
        #expect(mock.capturedIsSharingProvider?() == false)
        #expect(mock.capturedFrameProvider?() == nil)
    }

    @MainActor @Test func startWebServiceReturnsFalseWhenControllerFails() {
        let mock = MockWebServiceController()
        mock.startResult = false
        let sut = SharingService(webServiceController: mock)

        let started = sut.startWebService()

        #expect(started == false)
        #expect(mock.startCallCount == 1)
        #expect(sut.isWebServiceRunning == false)
    }

    @MainActor @Test func stopSharingDisconnectsAllStreamClients() {
        let mock = MockWebServiceController()
        let sut = SharingService(webServiceController: mock)

        sut.stopSharing()
        sut.stopSharing()

        #expect(mock.disconnectCallCount == 2)
        #expect(sut.isSharing == false)
    }

    @MainActor @Test func stopWebServiceStopsControllerAndDisconnectsAllStreamClients() {
        let mock = MockWebServiceController()
        let sut = SharingService(webServiceController: mock)

        sut.stopWebService()

        #expect(mock.stopCallCount == 1)
        #expect(mock.disconnectCallCount == 1)
        #expect(sut.isWebServiceRunning == false)
    }
}
