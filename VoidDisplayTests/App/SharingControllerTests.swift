import CoreGraphics
import Testing
@testable import VoidDisplay

@MainActor
struct SharingControllerTests {
    @Test func startWebServiceSyncsState() async {
        let service = MockSharingService()
        service.startResult = true
        service.activeStreamClientCount = 2
        let displayID: CGDirectDisplayID = 8001
        service.activeSharingDisplayIDs = [displayID]
        service.hasAnyActiveSharing = true

        let sut = SharingController(sharingService: service)

        let started = await sut.startWebService()

        #expect(started)
        #expect(sut.isWebServiceRunning)
        #expect(sut.isSharing)
        #expect(sut.sharingClientCount == 2)
        #expect(sut.activeSharingDisplayIDs.contains(displayID))
    }

    @Test func stopSharingAndStopAllSharingSyncState() {
        let service = MockSharingService()
        let first: CGDirectDisplayID = 11
        let second: CGDirectDisplayID = 12
        service.isWebServiceRunning = true
        service.activeSharingDisplayIDs = [first, second]
        service.hasAnyActiveSharing = true

        let sut = SharingController(sharingService: service)

        sut.stopSharing(displayID: first)
        #expect(!sut.activeSharingDisplayIDs.contains(first))

        sut.stopAllSharing()
        #expect(sut.activeSharingDisplayIDs.isEmpty)
        #expect(!sut.isSharing)
        #expect(service.stopSharingCallCount == 1)
        #expect(service.stopAllSharingCallCount == 1)
    }

    @Test func sharePageURLResolutionReturnsServiceNotRunningWhenStopped() {
        let service = MockSharingService()
        service.isWebServiceRunning = false
        let sut = SharingController(sharingService: service)

        let result = sut.sharePageURLResolution(for: nil)

        #expect(result == .failure(.serviceNotRunning))
    }
}
