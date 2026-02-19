import Foundation
import CoreGraphics
import Testing
@testable import FreelyDisplay

struct SharingServiceTests {

    @MainActor @Test func startWebServiceDelegatesToControllerAndCapturesProviders() async {
        let mock = MockWebServiceController()
        let sut = SharingService(webServiceController: mock)

        let started = await sut.startWebService()

        #expect(started)
        #expect(mock.startCallCount == 1)
        #expect(sut.webServicePortValue == 9090)
        #expect(sut.isWebServiceRunning)
        #expect(mock.capturedTargetStateProvider?(.main) == .knownInactive)
        #expect(mock.capturedTargetStateProvider?(.id(123)) == .unknown)
        #expect(mock.capturedFrameProvider?(.main) == nil)
    }

    @MainActor @Test func startWebServiceReturnsFalseWhenControllerFails() async {
        let mock = MockWebServiceController()
        mock.startResult = false
        let sut = SharingService(webServiceController: mock)

        let started = await sut.startWebService()

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

    @MainActor @Test func forwardsWebServiceRunningStateCallbackFromController() {
        let mock = MockWebServiceController()
        let sut = SharingService(webServiceController: mock)
        var receivedStates: [Bool] = []

        sut.onWebServiceRunningStateChanged = { isRunning in
            receivedStates.append(isRunning)
        }

        mock.onRunningStateChanged?(true)
        mock.onRunningStateChanged?(false)

        #expect(receivedStates == [true, false])
    }

    @MainActor @Test func startAndStopEmitRunningStateChanges() async {
        let mock = MockWebServiceController()
        let sut = SharingService(webServiceController: mock)
        var receivedStates: [Bool] = []

        sut.onWebServiceRunningStateChanged = { isRunning in
            receivedStates.append(isRunning)
        }

        #expect(await sut.startWebService())
        sut.stopWebService()

        #expect(receivedStates == [true, false])
    }
}
