import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing
@testable import VoidDisplay

@Suite(.serialized)
@MainActor
struct CaptureChooseViewModelTests {
    @Test func displayHelpersUseDisplayMetadataAndVirtualQuery() {
        let sut = CaptureChooseViewModel(
            dependencies: .init(
                captureActions: .init(
                    monitoringSessionForDisplayID: { _ in nil },
                    isStartingDisplayID: { _ in false },
                    startMonitoring: { _, _ in .started(UUID()) }
                ),
                virtualDisplayQueries: .init(
                    isManagedVirtualDisplay: { $0 == 1234 }
                )
            )
        )
        let display = SharedMockSCDisplay.make(displayID: 1234, width: 1920, height: 1080)

        #expect(sut.isVirtualDisplay(display))
        #expect(sut.resolutionText(for: display) == "1920 × 1080")
        #expect(sut.displayName(for: display) == String(localized: "Monitor"))
    }

    @Test func dependenciesLiveDelegatesToControllers() {
        let captureService = MockCaptureMonitoringService()
        let captureController = CaptureController(captureMonitoringService: captureService)
        captureController.installStartingDisplayIDsForTesting([777])
        let virtualDisplayController = VirtualDisplayController(
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            appliedBadgeDisplayDuration: .nanoseconds(1),
            stopDependentStreamsBeforeRebuild: { _ in }
        )
        let dependencies = CaptureChooseViewModel.Dependencies.live(
            capture: captureController,
            virtualDisplay: virtualDisplayController
        )

        #expect(dependencies.captureActions.monitoringSessionForDisplayID(777) == nil)
        #expect(dependencies.captureActions.isStartingDisplayID(777))
        #expect(dependencies.virtualDisplayQueries.isManagedVirtualDisplay(777) == false)
    }

    @Test func isStartingDelegatesToCaptureActions() {
        let sut = CaptureChooseViewModel(
            dependencies: .init(
                captureActions: .init(
                    monitoringSessionForDisplayID: { _ in nil },
                    isStartingDisplayID: { $0 == 301 },
                    startMonitoring: { _, _ in .started(UUID()) }
                ),
                virtualDisplayQueries: .init(
                    isManagedVirtualDisplay: { _ in false }
                )
            )
        )

        #expect(sut.isStarting(displayID: 301))
        #expect(sut.isStarting(displayID: 302) == false)
    }

    @Test func startMonitoringFailurePresentsUserFacingAlert() async {
        struct ControlledError: LocalizedError {
            var errorDescription: String? { "preview failed" }
        }

        let sut = CaptureChooseViewModel(
            dependencies: .init(
                captureActions: .init(
                    monitoringSessionForDisplayID: { _ in nil },
                    isStartingDisplayID: { _ in false },
                    startMonitoring: { _, _ in
                        throw ControlledError()
                    }
                ),
                virtualDisplayQueries: .init(
                    isManagedVirtualDisplay: { _ in false }
                )
            )
        )
        let display = SharedMockSCDisplay.make(displayID: 777, width: 1920, height: 1080)
        var openedSessionIDs: [UUID] = []

        await sut.startMonitoring(display: display) { openedSessionIDs.append($0) }

        #expect(openedSessionIDs.isEmpty)
        #expect(sut.userFacingAlert?.title == String(localized: "Start Monitoring Failed"))
        #expect(sut.userFacingAlert?.message.isEmpty == false)
    }

    @Test func startMonitoringCancellationDoesNotPresentUserFacingAlert() async {
        let sut = CaptureChooseViewModel(
            dependencies: .init(
                captureActions: .init(
                    monitoringSessionForDisplayID: { _ in nil },
                    isStartingDisplayID: { _ in false },
                    startMonitoring: { _, _ in
                        throw CancellationError()
                    }
                ),
                virtualDisplayQueries: .init(
                    isManagedVirtualDisplay: { _ in false }
                )
            )
        )
        let display = SharedMockSCDisplay.make(displayID: 779, width: 1920, height: 1080)
        var openedSessionIDs: [UUID] = []

        await sut.startMonitoring(display: display) { openedSessionIDs.append($0) }

        #expect(openedSessionIDs.isEmpty)
        #expect(sut.userFacingAlert == nil)
    }

    @Test func startMonitoringSuccessPassesMetadataToCaptureActions() async {
        let expectedSessionID = UUID()
        let display = SharedMockSCDisplay.make(displayID: 778, width: 2560, height: 1440)
        var receivedDisplayID: CGDirectDisplayID?
        var receivedMetadata: CaptureMonitoringDisplayMetadata?
        let sut = CaptureChooseViewModel(
            dependencies: .init(
                captureActions: .init(
                    monitoringSessionForDisplayID: { _ in nil },
                    isStartingDisplayID: { _ in false },
                    startMonitoring: { display, metadata in
                        receivedDisplayID = display.displayID
                        receivedMetadata = metadata
                        return .started(expectedSessionID)
                    }
                ),
                virtualDisplayQueries: .init(
                    isManagedVirtualDisplay: { $0 == 778 }
                )
            )
        )
        var openedSessionIDs: [UUID] = []

        await sut.startMonitoring(display: display) { openedSessionIDs.append($0) }

        #expect(receivedDisplayID == 778)
        #expect(receivedMetadata == CaptureMonitoringDisplayMetadata(
            displayName: String(localized: "Monitor"),
            resolutionText: "2560 × 1440",
            isVirtualDisplay: true
        ))
        #expect(openedSessionIDs == [expectedSessionID])
        #expect(sut.userFacingAlert == nil)
    }

    @Test func startMonitoringInvalidationDoesNotPresentUserFacingAlert() async {
        let sut = CaptureChooseViewModel(
            dependencies: .init(
                captureActions: .init(
                    monitoringSessionForDisplayID: { _ in nil },
                    isStartingDisplayID: { _ in false },
                    startMonitoring: { _, _ in .invalidated }
                ),
                virtualDisplayQueries: .init(
                    isManagedVirtualDisplay: { _ in false }
                )
            )
        )
        let display = SharedMockSCDisplay.make(displayID: 780, width: 1920, height: 1080)
        var openedSessionIDs: [UUID] = []

        await sut.startMonitoring(display: display) { openedSessionIDs.append($0) }

        #expect(openedSessionIDs.isEmpty)
        #expect(sut.userFacingAlert == nil)
    }

    @Test func visibleDisplaysFiltersDisplaysMissingFromCurrentTopology() {
        let displayA = SharedMockSCDisplay.make(displayID: 1111, width: 1920, height: 1080)
        let displayB = SharedMockSCDisplay.make(displayID: 2222, width: 1920, height: 1080)
        let sut = CaptureChooseViewModel(
            activeDisplayIDsProvider: { Set<CGDirectDisplayID>([1111]) },
            dependencies: makeNoopCaptureDependencies()
        )

        let visible = sut.visibleDisplays(from: [displayA, displayB])
        #expect(visible.map(\.displayID) == [1111])
    }

    private func makeNoopCaptureDependencies() -> CaptureChooseViewModel.Dependencies {
        .init(
            captureActions: .init(
                monitoringSessionForDisplayID: { _ in nil },
                isStartingDisplayID: { _ in false },
                startMonitoring: { _, _ in .started(UUID()) }
            ),
            virtualDisplayQueries: .init(
                isManagedVirtualDisplay: { _ in false }
            )
        )
    }
}
