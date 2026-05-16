@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
import Foundation
import ScreenCaptureKit
import Testing

@Suite(.serialized)
@MainActor
struct CaptureChooseViewModelTests {
    @Test func displayHelpersUseDisplayMetadataAndVirtualQuery() {
        let sut = CaptureChooseViewModel(
            dependencies: .init(
                captureActions: makeCaptureActions(),
                virtualDisplayStatusProvider: .init(
                    isManagedVirtualDisplay: { $0 == 1234 }
                )
            )
        )
        let display = SharedMockSCDisplay.make(displayID: 1234, width: 1920, height: 1080)

        #expect(sut.isVirtualDisplay(display))
        #expect(sut.resolutionText(for: display) == "1920 × 1080")
        #expect(sut.displayName(for: display) == String(localized: "Display"))
    }

    @Test func startPreviewFailurePresentsUserFacingAlert() async {
        struct ControlledError: LocalizedError {
            var errorDescription: String? { "preview failed" }
        }

        let sut = CaptureChooseViewModel(
            dependencies: .init(
                captureActions: makeCaptureActions(
                    startPreview: { _, _ in
                        throw ControlledError()
                    }
                ),
                virtualDisplayStatusProvider: .init(
                    isManagedVirtualDisplay: { _ in false }
                )
            )
        )
        let display = SharedMockSCDisplay.make(displayID: 777, width: 1920, height: 1080)
        var openedSessionIDs: [UUID] = []

        await sut.startPreview(display: display) { openedSessionIDs.append($0) }

        #expect(openedSessionIDs.isEmpty)
        #expect(sut.userFacingAlert?.title == String(localized: "Start Preview Failed"))
        #expect(sut.userFacingAlert?.message.isEmpty == false)
    }

    @Test func startPreviewCancellationDoesNotPresentUserFacingAlert() async {
        let sut = CaptureChooseViewModel(
            dependencies: .init(
                captureActions: makeCaptureActions(
                    startPreview: { _, _ in
                        throw CancellationError()
                    }
                ),
                virtualDisplayStatusProvider: .init(
                    isManagedVirtualDisplay: { _ in false }
                )
            )
        )
        let display = SharedMockSCDisplay.make(displayID: 779, width: 1920, height: 1080)
        var openedSessionIDs: [UUID] = []

        await sut.startPreview(display: display) { openedSessionIDs.append($0) }

        #expect(openedSessionIDs.isEmpty)
        #expect(sut.userFacingAlert == nil)
    }

    @Test func startPreviewSuccessPassesMetadataToCaptureActions() async {
        let expectedSessionID = UUID()
        let display = SharedMockSCDisplay.make(displayID: 778, width: 2560, height: 1440)
        var receivedDisplayID: CGDirectDisplayID?
        var receivedMetadata: CapturePreviewDisplayMetadata?
        let sut = CaptureChooseViewModel(
            dependencies: .init(
                captureActions: makeCaptureActions(
                    startPreview: { display, metadata in
                        receivedDisplayID = display.displayID
                        receivedMetadata = metadata
                        return .started(expectedSessionID)
                    }
                ),
                virtualDisplayStatusProvider: .init(
                    isManagedVirtualDisplay: { $0 == 778 }
                )
            )
        )
        var openedSessionIDs: [UUID] = []

        await sut.startPreview(display: display) { openedSessionIDs.append($0) }

        #expect(receivedDisplayID == 778)
        #expect(receivedMetadata == CapturePreviewDisplayMetadata(
            displayName: String(localized: "Display"),
            resolutionText: "2560 × 1440",
            isVirtualDisplay: true
        ))
        #expect(openedSessionIDs == [expectedSessionID])
        #expect(sut.userFacingAlert == nil)
    }

    @Test func startPreviewInvalidationDoesNotPresentUserFacingAlert() async {
        let sut = CaptureChooseViewModel(
            dependencies: .init(
                captureActions: makeCaptureActions(
                    startPreview: { _, _ in .invalidated }
                ),
                virtualDisplayStatusProvider: .init(
                    isManagedVirtualDisplay: { _ in false }
                )
            )
        )
        let display = SharedMockSCDisplay.make(displayID: 780, width: 1920, height: 1080)
        var openedSessionIDs: [UUID] = []

        await sut.startPreview(display: display) { openedSessionIDs.append($0) }

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
            captureActions: makeCaptureActions(),
            virtualDisplayStatusProvider: .init(
                isManagedVirtualDisplay: { _ in false }
            )
        )
    }

    private func makeCaptureActions(
        startPreview: @escaping @MainActor (
            SCDisplay,
            CapturePreviewDisplayMetadata
        ) async throws -> DisplayStartOutcome<UUID> = { _, _ in .started(UUID()) }
    ) -> CapturePreviewActions {
        .init(
            sessions: { [] },
            previewSession: { _ in nil },
            previewSessionForDisplayID: { _ in nil },
            isStartingDisplayID: { _ in false },
            startPreview: startPreview,
            attachPreviewSink: { _, _ in },
            activatePreviewSession: { _ in },
            attachDiagnosticsRecorder: { _ in nil },
            detachDiagnosticsRecorder: { _ in },
            closePreviewSession: { _ in },
            setPreviewSessionCapturesCursor: { _, _ in }
        )
    }

}
