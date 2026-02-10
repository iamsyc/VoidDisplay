import Foundation
import CoreGraphics
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
        #expect(mock.capturedTargetStateProvider?(.main) == .knownInactive)
        #expect(mock.capturedTargetStateProvider?(.id(123)) == .unknown)
        #expect(mock.capturedFrameProvider?(.main) == nil)
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

    @MainActor @Test func stopSingleSharingKeepsConnectionManagementInTargetHub() {
        let mock = MockWebServiceController()
        let sut = SharingService(webServiceController: mock)

        sut.stopSharing(displayID: CGDirectDisplayID(11))
        sut.stopSharing(displayID: CGDirectDisplayID(11))

        #expect(mock.disconnectCallCount == 0)
        #expect(sut.hasAnyActiveSharing == false)
    }

    @MainActor @Test func stopWebServiceStopsControllerAndDisconnectsAllStreamClients() {
        let mock = MockWebServiceController()
        let sut = SharingService(webServiceController: mock)

        sut.stopWebService()

        #expect(mock.stopCallCount == 1)
        #expect(mock.disconnectCallCount == 1)
        #expect(sut.isWebServiceRunning == false)
    }

    @MainActor @Test func activeStreamClientCountReflectsControllerValue() {
        let mock = MockWebServiceController()
        mock.activeStreamClientCount = 3
        let sut = SharingService(webServiceController: mock)

        #expect(sut.activeStreamClientCount == 3)
    }
}
