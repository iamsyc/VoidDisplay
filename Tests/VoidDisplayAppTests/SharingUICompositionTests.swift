@testable import VoidDisplayApp
@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
@testable import VoidDisplayRuntime
@testable import VoidDisplaySharing
@testable import VoidDisplayTestingSupport
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayVirtualDisplayTestingSupport
import Foundation
import Testing

@Suite(.serialized)
@MainActor
struct SharingUICompositionTests {
    @Test func runtimeStateReflectsSharingControllerState() {
        let displayID: UInt32 = 501
        let target = ShareTarget.id(9001)
        let sharingService = MockSharingService()
        sharingService.isWebServiceRunning = true
        sharingService.webServiceLifecycleState = .running(
            WebServiceBinding(requestedPort: 8081, boundPort: 8081)
        )
        sharingService.activeSharingDisplayIDs = [displayID]
        sharingService.hasAnyActiveSharing = true
        sharingService.shareTargetByDisplayID[displayID] = target
        sharingService.updateSharingStateSnapshot(
            SharingStateSnapshot(
                signalingConnections: 2,
                streamingPeers: 2,
                signalingConnectionsByTarget: [target: 2],
                streamingPeersByTarget: [target: 2],
                clientsByTarget: [:],
                lastUpdatedAt: Date()
            )
        )
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: SharingPortPreferences(
                defaults: UserDefaults(suiteName: "SharingUICompositionTestsRuntime")!
            )
        )

        let state = SharingUIComposition.runtimeState(sharing: sharingController)

        #expect(state.isWebServiceRunning)
        #expect(state.isDisplaySharing(displayID: displayID))
        #expect(state.sharingClientCount == 2)
        #expect(state.displayClientCount(for: displayID) == 2)
    }

    @Test func dependenciesDelegateQueriesToControllers() {
        let sharingService = MockSharingService()
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: SharingPortPreferences(
                defaults: UserDefaults(suiteName: "SharingUICompositionTestsLive")!
            )
        )
        let virtualDisplayController = VirtualDisplayController(
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let dependencies = SharingUIComposition.dependencies(
            sharing: sharingController,
            virtualDisplay: virtualDisplayController,
            displayRuntime: DisplayRuntime()
        )

        #expect(
            dependencies.sharingQueries.preferredWebServicePort()
                == sharingController.preferredWebServicePort
        )
    }

    @Test func performanceModeBindingMapsToCapturePreferences() {
        let suiteName = "SharingUICompositionTests.performance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = CapturePerformancePreferences(defaults: defaults)
        let binding = SharingUIComposition.performanceModeBinding(
            capturePerformancePreferences: preferences
        )

        #expect(binding.get() == .automatic)

        binding.set(.smooth)

        #expect(preferences.mode == .smooth)
        #expect(binding.get() == .smooth)
    }
}
