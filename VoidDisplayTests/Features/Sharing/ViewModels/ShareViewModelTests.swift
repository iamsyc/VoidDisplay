import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing
@testable import VoidDisplay

@Suite(.serialized)
@MainActor
struct ShareViewModelTests {
    @Test func dependenciesLiveDelegatesToControllers() {
        let sharingService = MockSharingService()
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: SharingPortPreferences(defaults: UserDefaults(suiteName: "ShareViewModelTestsLive")!)
        )
        sharingController.installStartingDisplayIDsForTesting([501])
        let virtualDisplayController = VirtualDisplayController(
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            appliedBadgeDisplayDuration: .nanoseconds(1),
            stopDependentStreamsBeforeRebuild: { _ in }
        )
        let dependencies = ShareViewModel.Dependencies.live(
            sharing: sharingController,
            virtualDisplay: virtualDisplayController
        )

        #expect(dependencies.sharingQueries.isStartingDisplayID(501))
        #expect(
            dependencies.sharingQueries.preferredWebServicePort()
                == sharingController.preferredWebServicePort
        )
    }

    @Test func dependenciesLiveReflectsStopWebServiceClearingStartingState() {
        let sharingService = MockSharingService()
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: SharingPortPreferences(defaults: UserDefaults(suiteName: "ShareViewModelTestsStopWebService")!)
        )
        sharingController.installStartingDisplayIDsForTesting([502])
        let virtualDisplayController = VirtualDisplayController(
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            appliedBadgeDisplayDuration: .nanoseconds(1),
            stopDependentStreamsBeforeRebuild: { _ in }
        )
        let dependencies = ShareViewModel.Dependencies.live(
            sharing: sharingController,
            virtualDisplay: virtualDisplayController
        )

        #expect(dependencies.sharingQueries.isStartingDisplayID(502))

        sharingController.stopWebService()

        #expect(dependencies.sharingQueries.isStartingDisplayID(502) == false)
    }

    @Test func isStartingDelegatesToSharingQueries() {
        let sut = ShareViewModel(
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { false },
                    isStartingDisplayID: { $0 == 101 },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .failed(.timedOut(port: 8081)) },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in },
                    beginSharing: { _ in .started(()) },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )

        #expect(sut.isStarting(displayID: 101))
        #expect(sut.isStarting(displayID: 102) == false)
    }

    @Test func visibleDisplaysFiltersDisplaysMissingFromCurrentTopology() {
        let displayA = SharedMockSCDisplay.make(displayID: 1234, width: 1920, height: 1080)
        let displayB = SharedMockSCDisplay.make(displayID: 5678, width: 1920, height: 1080)
        let sut = ShareViewModel(
            activeDisplayIDsProvider: { Set<CGDirectDisplayID>([1234]) },
            dependencies: makeAlwaysRunningShareDependencies()
        )

        let visible = sut.visibleDisplays(from: [displayA, displayB])
        #expect(visible.map(\.displayID) == [1234])
    }

    @Test func startServiceFailureShowsInlinePortError() async {
        let sharing = MockSharingService()
        sharing.startResult = .failed(.portInUse(port: 8081))
        let env = makeEnvironment(sharing: sharing)
        let sut = ShareViewModel(
            dependencies: .live(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        )

        sut.startService()
        let presented = await waitUntil {
            sut.portInputErrorMessage != nil
        }

        #expect(presented)
        #expect(sharing.startWebServiceCallCount == 1)
        #expect(sut.userFacingAlert == nil)
    }

    @Test func initUsesPreferredPortAsInputDefault() {
        let sut = ShareViewModel(
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { false },
                    isStartingDisplayID: { _ in false },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 9099 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .failed(.timedOut(port: 9099)) },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in },
                    beginSharing: { _ in .started(()) },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )

        #expect(sut.servicePortInput == "9099")
    }

    @Test func servicePortInputTruncatesToFiveCharacters() {
        let env = makeEnvironment()
        let sut = ShareViewModel(
            dependencies: .live(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        )

        sut.servicePortInput = "1234567890"

        #expect(sut.servicePortInput == "12345")
    }

    @Test func startServiceWithInvalidPortSkipsStartCallAndShowsValidationError() async {
        let sharing = MockSharingService()
        let env = makeEnvironment(sharing: sharing)
        let sut = ShareViewModel(
            dependencies: .live(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        )
        sut.servicePortInput = "abc"

        sut.startService()
        let presented = await waitUntil {
            sut.portInputErrorMessage != nil
        }

        #expect(presented)
        #expect(sharing.startWebServiceCallCount == 0)
        #expect(sut.userFacingAlert == nil)
    }

    @Test func startServicePassesRequestedPortToSharingLayer() async {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let sharing = MockSharingService()
        sharing.startResult = .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort))
        let env = makeEnvironment(sharing: sharing)
        let sut = ShareViewModel(
            dependencies: .live(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        )
        sut.servicePortInput = String(requestedPort)

        sut.startService()
        let started = await waitUntil {
            sharing.startWebServiceCallCount == 1
        }

        #expect(started)
        #expect(sharing.lastStartRequestedPort == requestedPort)
    }

    @Test func stopServiceDelegatesToSharingLayer() {
        var stopCallCount = 0
        let sut = ShareViewModel(
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { true },
                    isStartingDisplayID: { _ in false },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081)) },
                    stopWebService: { stopCallCount += 1 },
                    registerShareableDisplays: { _, _ in },
                    beginSharing: { _ in .started(()) },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )

        sut.stopService()

        #expect(stopCallCount == 1)
    }

    @Test func startSharingWithInvalidPortSkipsServiceStartAndSharing() async {
        let display = SharedMockSCDisplay.make(displayID: 7001, width: 1920, height: 1080)
        var startCallCount = 0
        var beginSharingCallCount = 0
        let sut = ShareViewModel(
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { false },
                    isStartingDisplayID: { _ in false },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in
                        startCallCount += 1
                        return .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081))
                    },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in },
                    beginSharing: { _ in
                        beginSharingCallCount += 1
                        return .started(())
                    },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )
        sut.servicePortInput = "abc"

        await sut.startSharing(display: display)

        #expect(startCallCount == 0)
        #expect(beginSharingCallCount == 0)
        #expect(sut.portInputErrorMessage != nil)
        #expect(sut.userFacingAlert == nil)
    }

    @Test func startSharingServiceStartFailureShowsInlineErrorAndSkipsSharing() async {
        let display = SharedMockSCDisplay.make(displayID: 7002, width: 1920, height: 1080)
        var beginSharingCallCount = 0
        let sut = ShareViewModel(
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { false },
                    isStartingDisplayID: { _ in false },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .failed(.portInUse(port: 8081)) },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in },
                    beginSharing: { _ in
                        beginSharingCallCount += 1
                        return .started(())
                    },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )

        await sut.startSharing(display: display)

        #expect(beginSharingCallCount == 0)
        #expect(sut.portInputErrorMessage != nil)
        #expect(sut.userFacingAlert == nil)
    }

    @Test func startSharingFailureStopsShareAndPresentsLocalizedAlert() async {
        let display = SharedMockSCDisplay.make(displayID: 7003, width: 1920, height: 1080)
        var stopSharingDisplayIDs: [CGDirectDisplayID] = []
        let sut = ShareViewModel(
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { true },
                    isStartingDisplayID: { _ in false },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081)) },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in },
                    beginSharing: { _ in
                        throw SharingStartError.displayNotRegistered(display.displayID)
                    },
                    stopSharing: { displayID in
                        stopSharingDisplayIDs.append(displayID)
                    }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )

        await sut.startSharing(display: display)

        #expect(stopSharingDisplayIDs == [display.displayID])
        #expect(sut.userFacingAlert?.title == String(localized: "Share Failed"))
        #expect(sut.userFacingAlert?.message == String(localized: "Selected display is no longer available for sharing."))
        #expect(sut.portInputErrorMessage == nil)
    }

    @Test func startSharingInvalidationEndsSilentlyWithoutStoppingShare() async {
        let display = SharedMockSCDisplay.make(displayID: 7004, width: 1920, height: 1080)
        var stopSharingCallCount = 0
        let sut = ShareViewModel(
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { true },
                    isStartingDisplayID: { _ in false },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081)) },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in },
                    beginSharing: { _ in .invalidated },
                    stopSharing: { _ in
                        stopSharingCallCount += 1
                    }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )

        await sut.startSharing(display: display)

        #expect(stopSharingCallCount == 0)
        #expect(sut.userFacingAlert == nil)
        #expect(sut.portInputErrorMessage == nil)
    }

    @Test func startSharingWithRunningServiceDelegatesToSharingLayer() async {
        let display = SharedMockSCDisplay.make(displayID: 7005, width: 1920, height: 1080)
        var beginSharingCallCount = 0
        let sut = ShareViewModel(
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { true },
                    isStartingDisplayID: { _ in false },
                    sharePageAddress: { _ in nil },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081)) },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in },
                    beginSharing: { _ in
                        beginSharingCallCount += 1
                        return .started(())
                    },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )

        await sut.startSharing(display: display)

        #expect(beginSharingCallCount == 1)
        #expect(sut.userFacingAlert == nil)
        #expect(sut.portInputErrorMessage == nil)
    }

    @Test func editingPortClearsInlineErrorMessage() async {
        let sharing = MockSharingService()
        let env = makeEnvironment(sharing: sharing)
        let sut = ShareViewModel(
            dependencies: .live(sharing: env.sharing, virtualDisplay: env.virtualDisplay)
        )

        sut.servicePortInput = "bad-port"
        sut.startService()
        _ = await waitUntil { sut.portInputErrorMessage != nil }
        #expect(sut.portInputErrorMessage != nil)

        sut.servicePortInput = "8081"
        #expect(sut.portInputErrorMessage == nil)
    }

    @Test func sharePageAddressDelegatesToSharingQueries() {
        let sut = ShareViewModel(
            dependencies: .init(
                sharingQueries: .init(
                    isWebServiceRunning: { true },
                    isStartingDisplayID: { _ in false },
                    sharePageAddress: { _ in "http://127.0.0.1:8081/display/1" },
                    preferredWebServicePort: { 8081 }
                ),
                sharingActions: .init(
                    startWebService: { _ in .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081)) },
                    stopWebService: {},
                    registerShareableDisplays: { _, _ in },
                    beginSharing: { _ in .started(()) },
                    stopSharing: { _ in }
                ),
                virtualDisplayQueries: .init(
                    virtualSerialForManagedDisplay: { _ in nil }
                )
            )
        )

        #expect(sut.sharePageAddress(for: 1) == "http://127.0.0.1:8081/display/1")
    }

    private func makeEnvironment() -> AppEnvironment {
        makeEnvironment(sharing: MockSharingService())
    }

    private func makeEnvironment(sharing: MockSharingService) -> AppEnvironment {
        AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: sharing,
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            isRunningUnderXCTestOverride: false
        )
    }

    private func makeAlwaysRunningShareDependencies() -> ShareViewModel.Dependencies {
        .init(
            sharingQueries: .init(
                isWebServiceRunning: { true },
                isStartingDisplayID: { _ in false },
                sharePageAddress: { _ in nil },
                preferredWebServicePort: { 8081 }
            ),
            sharingActions: .init(
                startWebService: { _ in .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081)) },
                stopWebService: {},
                registerShareableDisplays: { _, _ in },
                beginSharing: { _ in .started(()) },
                stopSharing: { _ in }
            ),
            virtualDisplayQueries: .init(
                virtualSerialForManagedDisplay: { _ in nil }
            )
        )
    }
}
