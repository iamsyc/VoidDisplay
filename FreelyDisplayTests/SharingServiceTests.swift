import Foundation
import Testing
@testable import FreelyDisplay

@MainActor
private final class MockWebServiceController: WebServiceControlling {
    var portValue: UInt16 = 9090
    var currentServer: WebServer?
    var isRunning = false

    var startResult = true
    var startCallCount = 0
    var stopCallCount = 0
    var disconnectCallCount = 0
    var capturedIsSharingProvider: (@MainActor @Sendable () -> Bool)?
    var capturedFrameProvider: (@MainActor @Sendable () -> Data?)?

    func start(
        isSharingProvider: @escaping @MainActor @Sendable () -> Bool,
        frameProvider: @escaping @MainActor @Sendable () -> Data?
    ) -> Bool {
        startCallCount += 1
        capturedIsSharingProvider = isSharingProvider
        capturedFrameProvider = frameProvider
        isRunning = startResult
        return startResult
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
    }

    func disconnectStreamClient() {
        disconnectCallCount += 1
    }
}

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

    @MainActor @Test func stopSharingDisconnectsStreamClient() {
        let mock = MockWebServiceController()
        let sut = SharingService(webServiceController: mock)

        sut.stopSharing()
        sut.stopSharing()

        #expect(mock.disconnectCallCount == 2)
        #expect(sut.isSharing == false)
    }

    @MainActor @Test func stopWebServiceStopsControllerAndDisconnectsClient() {
        let mock = MockWebServiceController()
        let sut = SharingService(webServiceController: mock)

        sut.stopWebService()

        #expect(mock.stopCallCount == 1)
        #expect(mock.disconnectCallCount == 1)
        #expect(sut.isWebServiceRunning == false)
    }
}
