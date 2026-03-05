import CoreGraphics
import Testing
@testable import VoidDisplay

@MainActor
struct SharingControllerTests {
    @Test func startWebServiceSyncsState() async {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let service = MockSharingService()
        service.startResult = .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort))
        service.activeStreamClientCount = 2
        let displayID: CGDirectDisplayID = 8001
        service.activeSharingDisplayIDs = [displayID]
        service.hasAnyActiveSharing = true

        let sut = SharingController(
            sharingService: service,
            portPreferences: MockSharingPortPreferences()
        )

        let started = await sut.startWebService(requestedPort: requestedPort)

        #expect(started == .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)))
        #expect(sut.isWebServiceRunning)
        #expect(sut.isSharing)
        #expect(sut.sharingClientCount == 2)
        #expect(sut.activeSharingDisplayIDs.contains(displayID))
    }

    @Test func startWebServicePersistsRequestedPortOnSuccess() async {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let service = MockSharingService()
        service.startResult = .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort))
        let preferences = MockSharingPortPreferences()
        let sut = SharingController(
            sharingService: service,
            portPreferences: preferences
        )

        _ = await sut.startWebService(requestedPort: requestedPort)

        #expect(preferences.savedPorts == [requestedPort])
        #expect(sut.preferredWebServicePort == requestedPort)
    }

    @Test func stopSharingAndStopAllSharingSyncState() {
        let service = MockSharingService()
        let first: CGDirectDisplayID = 11
        let second: CGDirectDisplayID = 12
        service.isWebServiceRunning = true
        service.activeSharingDisplayIDs = [first, second]
        service.hasAnyActiveSharing = true

        let sut = SharingController(
            sharingService: service,
            portPreferences: MockSharingPortPreferences()
        )

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
        let sut = SharingController(
            sharingService: service,
            portPreferences: MockSharingPortPreferences()
        )

        let result = sut.sharePageURLResolution(for: nil)

        #expect(result == .failure(.serviceNotRunning))
    }
}

@MainActor
private final class MockSharingPortPreferences: SharingPortPreferencesProtocol {
    var preferredPort: UInt16 = 8081
    var savedPorts: [UInt16] = []

    func savePreferredPort(_ port: UInt16) {
        savedPorts.append(port)
        preferredPort = port
    }
}
