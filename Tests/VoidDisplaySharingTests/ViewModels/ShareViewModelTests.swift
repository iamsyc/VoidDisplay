@testable import VoidDisplayFoundation
@testable import VoidDisplaySharing
@testable import VoidDisplayTestingSupport
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing

@Suite(.serialized)
@MainActor
struct ShareViewModelTests {
    @Test func isStartingDelegatesToSharingQueries() {
        let sut = ShareViewModel(
            dependencies: makeShareDependencies(
                isStartingDisplayID: { $0 == 101 }
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
            dependencies: makeShareDependencies(isWebServiceRunning: { true })
        )

        let visible = sut.visibleDisplays(from: [displayA, displayB])
        #expect(visible.map(\.displayID) == [1234])
    }

    @Test func startServiceFailureShowsInlinePortError() async {
        var startWebServiceCallCount = 0
        let sut = ShareViewModel(
            dependencies: makeShareDependencies(
                startWebService: { _ in
                    startWebServiceCallCount += 1
                    return .failed(.portInUse(port: 8081))
                }
            )
        )

        sut.startService()
        let presented = await waitUntilViewModel {
            sut.portInputErrorMessage != nil
        }

        #expect(presented)
        #expect(startWebServiceCallCount == 1)
        #expect(sut.userFacingAlert == nil)
    }

    @Test func initUsesPreferredPortAsInputDefault() {
        let sut = ShareViewModel(
            dependencies: makeShareDependencies(preferredWebServicePort: { 9099 })
        )

        #expect(sut.servicePortInput == "9099")
    }

    @Test func servicePortInputTruncatesToFiveCharacters() {
        let sut = ShareViewModel(dependencies: makeShareDependencies())

        sut.servicePortInput = "1234567890"

        #expect(sut.servicePortInput == "12345")
    }

    @Test func startServiceWithInvalidPortSkipsStartCallAndShowsValidationError() async {
        var startWebServiceCallCount = 0
        let sut = ShareViewModel(
            dependencies: makeShareDependencies(
                startWebService: { _ in
                    startWebServiceCallCount += 1
                    return .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081))
                }
            )
        )
        sut.servicePortInput = "abc"

        sut.startService()
        let presented = await waitUntilViewModel {
            sut.portInputErrorMessage != nil
        }

        #expect(presented)
        #expect(startWebServiceCallCount == 0)
        #expect(sut.userFacingAlert == nil)
    }

    @Test func startServicePassesRequestedPortToSharingLayer() async {
        let requestedPort = randomUnprivilegedPort()
        var lastRequestedPort: UInt16?
        let sut = ShareViewModel(
            dependencies: makeShareDependencies(
                startWebService: { requestedPort in
                    lastRequestedPort = requestedPort
                    return .started(
                        WebServiceBinding(
                            requestedPort: requestedPort,
                            boundPort: requestedPort
                        )
                    )
                }
            )
        )
        sut.servicePortInput = String(requestedPort)

        sut.startService()
        let started = await waitUntilViewModel {
            lastRequestedPort != nil
        }

        #expect(started)
        #expect(lastRequestedPort == requestedPort)
    }

    @Test func stopServiceDelegatesToSharingLayer() {
        var stopCallCount = 0
        let sut = ShareViewModel(
            dependencies: makeShareDependencies(
                stopWebService: {
                    stopCallCount += 1
                }
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
            dependencies: makeShareDependencies(
                isWebServiceRunning: { false },
                startWebService: { _ in
                    startCallCount += 1
                    return .started(WebServiceBinding(requestedPort: 8081, boundPort: 8081))
                },
                beginSharing: { _ in
                    beginSharingCallCount += 1
                    return .started(())
                }
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
            dependencies: makeShareDependencies(
                isWebServiceRunning: { false },
                startWebService: { _ in .failed(.portInUse(port: 8081)) },
                beginSharing: { _ in
                    beginSharingCallCount += 1
                    return .started(())
                }
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
            dependencies: makeShareDependencies(
                isWebServiceRunning: { true },
                beginSharing: { _ in
                    throw SharingStartError.displayNotRegistered(display.displayID)
                },
                stopSharing: { displayID in
                    stopSharingDisplayIDs.append(displayID)
                }
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
            dependencies: makeShareDependencies(
                isWebServiceRunning: { true },
                beginSharing: { _ in .invalidated },
                stopSharing: { _ in
                    stopSharingCallCount += 1
                }
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
            dependencies: makeShareDependencies(
                isWebServiceRunning: { true },
                beginSharing: { _ in
                    beginSharingCallCount += 1
                    return .started(())
                }
            )
        )

        await sut.startSharing(display: display)

        #expect(beginSharingCallCount == 1)
        #expect(sut.userFacingAlert == nil)
        #expect(sut.portInputErrorMessage == nil)
    }

    @Test func editingPortClearsInlineErrorMessage() async {
        let sut = ShareViewModel(
            dependencies: makeShareDependencies(
                startWebService: { _ in .failed(.portInUse(port: 8081)) }
            )
        )

        sut.servicePortInput = "bad-port"
        sut.startService()
        _ = await waitUntilViewModel { sut.portInputErrorMessage != nil }
        #expect(sut.portInputErrorMessage != nil)

        sut.servicePortInput = "8081"
        #expect(sut.portInputErrorMessage == nil)
    }

    @Test func sharePageAddressDelegatesToSharingQueries() {
        let sut = ShareViewModel(
            dependencies: makeShareDependencies(
                sharePageAddress: { _ in "http://127.0.0.1:8081/display/1" }
            )
        )

        #expect(sut.sharePageAddress(for: 1) == "http://127.0.0.1:8081/display/1")
    }
}

@MainActor
private func makeShareDependencies(
    isWebServiceRunning: @escaping @MainActor () -> Bool = { true },
    activeSharingDisplayCount: @escaping @MainActor () -> Int = { 0 },
    sharingClientCount: @escaping @MainActor () -> Int = { 0 },
    isDisplaySharing: @escaping @MainActor (CGDirectDisplayID) -> Bool = { _ in false },
    isStartingDisplayID: @escaping @MainActor (CGDirectDisplayID) -> Bool = { _ in false },
    displayClientCount: @escaping @MainActor (CGDirectDisplayID) -> Int = { _ in 0 },
    sharePageAddress: @escaping @MainActor (CGDirectDisplayID) -> String? = { _ in nil },
    preferredWebServicePort: @escaping @MainActor () -> UInt16 = { 8081 },
    startWebService: @escaping @MainActor (UInt16) async -> WebServiceStartResult = {
        .started(WebServiceBinding(requestedPort: $0, boundPort: $0))
    },
    stopWebService: @escaping @MainActor () -> Void = {},
    beginSharing: @escaping @MainActor (SCDisplay) async throws -> DisplayStartOutcome<Void> = { _ in .started(()) },
    stopSharing: @escaping @MainActor (CGDirectDisplayID) -> Void = { _ in },
    virtualSerialForManagedDisplay: @escaping @MainActor (CGDirectDisplayID) -> UInt32? = { _ in nil }
) -> ShareViewModel.Dependencies {
    ShareViewModel.Dependencies(
        sharingQueries: .init(
            isWebServiceRunning: isWebServiceRunning,
            activeSharingDisplayCount: activeSharingDisplayCount,
            sharingClientCount: sharingClientCount,
            isDisplaySharing: isDisplaySharing,
            isStartingDisplayID: isStartingDisplayID,
            displayClientCount: displayClientCount,
            sharePageAddress: sharePageAddress,
            preferredWebServicePort: preferredWebServicePort
        ),
        sharingActions: .init(
            startWebService: startWebService,
            stopWebService: stopWebService,
            registerShareableDisplays: { _, _ in },
            beginSharing: beginSharing,
            stopSharing: stopSharing
        ),
        virtualDisplayQueries: .init(
            virtualSerialForManagedDisplay: virtualSerialForManagedDisplay
        )
    )
}

@MainActor
private func waitUntilViewModel(
    timeoutNanoseconds: UInt64 = 3_000_000_000,
    pollNanoseconds: UInt64 = 10_000_000,
    condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: pollNanoseconds)
    }
    return condition()
}

private func randomUnprivilegedPort() -> UInt16 {
    UInt16.random(in: 20_000...59_999)
}
