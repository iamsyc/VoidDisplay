@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing

private final class CaptureChooseDummySession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let shareFrameConsumer: any DisplayShareFrameConsumer = TestDisplayShareFrameConsumer()

    nonisolated func attachPreviewSink(_ _: any DisplayPreviewSink) {}

    nonisolated func detachPreviewSink(_ _: any DisplayPreviewSink) {}

    nonisolated func stopSharing() {}

    nonisolated func stop() async {}
}

@Suite(.serialized)
@MainActor
struct CaptureChooseViewModelTests {
    @Test func displayHelpersUseDisplayMetadataAndVirtualQuery() {
        let sut = CaptureChooseViewModel(
            dependencies: .init(
                captureActions: .init(
                    sessions: { [] },
                    monitoringSession: { _ in nil },
                    monitoringSessionForDisplayID: { _ in nil },
                    isStartingDisplayID: { _ in false },
                    startMonitoring: { _, _ in .started(UUID()) },
                    attachPreviewSink: { _, _ in },
                    activateMonitoringSession: { _ in },
                    closeMonitoringSession: { _ in },
                    setMonitoringSessionCapturesCursor: { _, _ in }
                ),
                virtualDisplayStatusProvider: .init(
                    isManagedVirtualDisplay: { $0 == 1234 }
                )
            )
        )
        let display = SharedMockSCDisplay.make(displayID: 1234, width: 1920, height: 1080)

        #expect(sut.isVirtualDisplay(display))
        #expect(sut.resolutionText(for: display) == "1920 × 1080")
        #expect(sut.displayName(for: display) == String(localized: "Monitor"))
    }

    @Test func dependenciesExposeClosureResults() {
        let sessionID = UUID()
        let displayID: CGDirectDisplayID = 777
        let session = makeSession(id: sessionID, displayID: displayID)
        let dependencies = CaptureChooseViewModel.Dependencies(
            captureActions: .init(
                sessions: { [session] },
                monitoringSession: { $0 == sessionID ? session : nil },
                monitoringSessionForDisplayID: { $0 == displayID ? session : nil },
                isStartingDisplayID: { $0 == displayID },
                startMonitoring: { _, _ in .started(sessionID) },
                attachPreviewSink: { _, _ in },
                activateMonitoringSession: { _ in },
                closeMonitoringSession: { _ in },
                setMonitoringSessionCapturesCursor: { _, _ in }
            ),
            virtualDisplayStatusProvider: .init(
                isManagedVirtualDisplay: { $0 == displayID }
            )
        )

        #expect(dependencies.captureActions.sessions().map(\.id) == [sessionID])
        #expect(dependencies.captureActions.monitoringSession(sessionID)?.id == sessionID)
        #expect(dependencies.captureActions.monitoringSessionForDisplayID(displayID)?.displayID == displayID)
        #expect(dependencies.captureActions.isStartingDisplayID(displayID))
        #expect(dependencies.virtualDisplayStatusProvider.isManagedVirtualDisplay(displayID))
    }

    @Test func isStartingDelegatesToCaptureActions() {
        let sut = CaptureChooseViewModel(
            dependencies: .init(
                captureActions: .init(
                    sessions: { [] },
                    monitoringSession: { _ in nil },
                    monitoringSessionForDisplayID: { _ in nil },
                    isStartingDisplayID: { $0 == 301 },
                    startMonitoring: { _, _ in .started(UUID()) },
                    attachPreviewSink: { _, _ in },
                    activateMonitoringSession: { _ in },
                    closeMonitoringSession: { _ in },
                    setMonitoringSessionCapturesCursor: { _, _ in }
                ),
                virtualDisplayStatusProvider: .init(
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
                    sessions: { [] },
                    monitoringSession: { _ in nil },
                    monitoringSessionForDisplayID: { _ in nil },
                    isStartingDisplayID: { _ in false },
                    startMonitoring: { _, _ in
                        throw ControlledError()
                    },
                    attachPreviewSink: { _, _ in },
                    activateMonitoringSession: { _ in },
                    closeMonitoringSession: { _ in },
                    setMonitoringSessionCapturesCursor: { _, _ in }
                ),
                virtualDisplayStatusProvider: .init(
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
                    sessions: { [] },
                    monitoringSession: { _ in nil },
                    monitoringSessionForDisplayID: { _ in nil },
                    isStartingDisplayID: { _ in false },
                    startMonitoring: { _, _ in
                        throw CancellationError()
                    },
                    attachPreviewSink: { _, _ in },
                    activateMonitoringSession: { _ in },
                    closeMonitoringSession: { _ in },
                    setMonitoringSessionCapturesCursor: { _, _ in }
                ),
                virtualDisplayStatusProvider: .init(
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
                    sessions: { [] },
                    monitoringSession: { _ in nil },
                    monitoringSessionForDisplayID: { _ in nil },
                    isStartingDisplayID: { _ in false },
                    startMonitoring: { display, metadata in
                        receivedDisplayID = display.displayID
                        receivedMetadata = metadata
                        return .started(expectedSessionID)
                    },
                    attachPreviewSink: { _, _ in },
                    activateMonitoringSession: { _ in },
                    closeMonitoringSession: { _ in },
                    setMonitoringSessionCapturesCursor: { _, _ in }
                ),
                virtualDisplayStatusProvider: .init(
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
                    sessions: { [] },
                    monitoringSession: { _ in nil },
                    monitoringSessionForDisplayID: { _ in nil },
                    isStartingDisplayID: { _ in false },
                    startMonitoring: { _, _ in .invalidated },
                    attachPreviewSink: { _, _ in },
                    activateMonitoringSession: { _ in },
                    closeMonitoringSession: { _ in },
                    setMonitoringSessionCapturesCursor: { _, _ in }
                ),
                virtualDisplayStatusProvider: .init(
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
                sessions: { [] },
                monitoringSession: { _ in nil },
                monitoringSessionForDisplayID: { _ in nil },
                isStartingDisplayID: { _ in false },
                startMonitoring: { _, _ in .started(UUID()) },
                attachPreviewSink: { _, _ in },
                activateMonitoringSession: { _ in },
                closeMonitoringSession: { _ in },
                setMonitoringSessionCapturesCursor: { _, _ in }
            ),
            virtualDisplayStatusProvider: .init(
                isManagedVirtualDisplay: { _ in false }
            )
        )
    }

    private func makeSession(
        id: UUID,
        displayID: CGDirectDisplayID
    ) -> ScreenMonitoringSession {
        let captureSession = CaptureChooseDummySession()
        return ScreenMonitoringSession(
            id: id,
            displayID: displayID,
            displayName: "Display",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false,
            previewSubscription: DisplayPreviewSubscription(
                displayID: displayID,
                resolutionText: "1920 × 1080",
                session: captureSession,
                cancelClosure: {}
            ),
            capturesCursor: false,
            state: .active
        )
    }
}
