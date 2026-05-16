@testable import VoidDisplayApp
@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
@testable import VoidDisplaySharingTestingSupport
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import Testing

private final class CaptureControllerDummySession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let sessionHub = TestSignalSessionHub()
    nonisolated var shareFrameConsumer: any DisplayShareFrameConsumer { sessionHub }

    nonisolated(unsafe) var attachedSinkCount = 0
    nonisolated(unsafe) var detachedSinkCount = 0
    nonisolated(unsafe) var cursorUpdateCount = 0
    nonisolated(unsafe) var lastShowsCursor: Bool?

    nonisolated func attachPreviewSink(_ _: any DisplayPreviewSink) {
        attachedSinkCount += 1
    }

    nonisolated func detachPreviewSink(_ _: any DisplayPreviewSink) {
        detachedSinkCount += 1
    }

    nonisolated func stopSharing() {}

    nonisolated func setDemand(_ demand: DisplayCaptureDemandSnapshot) async throws {
        cursorUpdateCount += 1
        lastShowsCursor = demand.previewShowsCursor
    }

    nonisolated func stop() async {}
}

private final class CaptureControllerPreviewSink: DisplayPreviewSink, @unchecked Sendable {
    nonisolated func submitFrame(_ _: CMSampleBuffer) {}
}

private final class CaptureControllerMockSCDisplayBox: NSObject {
    @objc let displayID: CGDirectDisplayID
    @objc let width: Int
    @objc let height: Int
    @objc let frame: CGRect

    init(displayID: CGDirectDisplayID, width: Int, height: Int) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.frame = CGRect(x: 0, y: 0, width: width, height: height)
        super.init()
    }
}

private enum CaptureControllerMockSCDisplay {
    static func make(displayID: CGDirectDisplayID, width: Int, height: Int) -> SCDisplay {
        let box = CaptureControllerMockSCDisplayBox(
            displayID: displayID,
            width: width,
            height: height
        )
        return unsafeBitCast(box, to: SCDisplay.self)
    }
}

private actor CaptureControllerAsyncGate {
    private var waitCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        waitCount += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseOne() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func currentWaitCount() -> Int {
        waitCount
    }
}

@MainActor
private final class CaptureControllerLifecycleSpy: CapturePreviewLifecycleServiceProtocol {
    typealias StartPreviewHandler = @MainActor (
        SCDisplay,
        CapturePreviewDisplayMetadata
    ) async throws -> DisplayStartOutcome<UUID>

    private let base: CapturePreviewLifecycleService
    private let eventRecorder: ((String) -> Void)?
    var startPreviewHandler: StartPreviewHandler?

    private(set) var removeByDisplayCallCount = 0
    private(set) var removedDisplayIDs: [CGDirectDisplayID] = []

    init(
        capturePreviewService: any CapturePreviewServiceProtocol,
        eventRecorder: ((String) -> Void)? = nil
    ) {
        self.base = CapturePreviewLifecycleService(capturePreviewService: capturePreviewService)
        self.eventRecorder = eventRecorder
    }

    func isStarting(displayID: CGDirectDisplayID) -> Bool {
        base.isStarting(displayID: displayID)
    }

    func startPreview(
        display: SCDisplay,
        metadata: CapturePreviewDisplayMetadata
    ) async throws -> DisplayStartOutcome<UUID> {
        if let startPreviewHandler {
            return try await startPreviewHandler(display, metadata)
        }
        return try await base.startPreview(display: display, metadata: metadata)
    }

    func activatePreviewSession(id: UUID) {
        base.activatePreviewSession(id: id)
    }

    func attachPreviewSink(_ sink: any DisplayPreviewSink, to id: UUID) {
        base.attachPreviewSink(sink, to: id)
    }

    func setPreviewSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) async throws {
        try await base.setPreviewSessionCapturesCursor(id: id, capturesCursor: capturesCursor)
    }

    func closePreviewSession(id: UUID) {
        base.closePreviewSession(id: id)
    }

    func removePreviewSessions(displayID: CGDirectDisplayID) {
        removeByDisplayCallCount += 1
        removedDisplayIDs.append(displayID)
        eventRecorder?("removePreview:\(displayID)")
        base.removePreviewSessions(displayID: displayID)
    }
}

@Suite(.serialized)
@MainActor
struct CaptureControllerTests {
    private struct SessionSnapshot: Equatable {
        let id: UUID
        let displayID: CGDirectDisplayID
        let capturesCursor: Bool
        let state: String
    }

    @Test func initSynchronizesExistingSessionsFromService() {
        let service = MockCapturePreviewService()
        let existingSession = makeSession(id: UUID(), displayID: 66).session
        service.currentSessions = [existingSession]

        let controller = CaptureController(capturePreviewService: service)

        #expect(controller.screenPreviewSessions.map(\.id) == [existingSession.id])
    }

    @Test func startPreviewRefreshesSnapshotFromLifecycleService() async throws {
        let service = MockCapturePreviewService()
        let subscriptionSession = CaptureControllerDummySession()
        let subscription = DisplayPreviewSubscription(
            displayID: 77,
            resolutionText: "2560 × 1440",
            session: subscriptionSession,
            cancelClosure: {},
            setShowsCursorClosure: { showsCursor in
                try await subscriptionSession.setDemand(
                    DisplayCaptureDemandSnapshot(
                        previewShowsCursor: showsCursor,
                        performanceMode: .automatic
                    )
                )
            }
        )
        let lifecycleService = CapturePreviewLifecycleService(
            capturePreviewService: service,
            acquirePreview: { _, _ in .started(subscription) }
        )
        let controller = CaptureController(
            capturePreviewService: service,
            capturePreviewLifecycleService: lifecycleService
        )
        let display = CaptureControllerMockSCDisplay.make(displayID: 77, width: 2560, height: 1440)
        let metadata = CapturePreviewDisplayMetadata(
            displayName: "Display 77",
            resolutionText: "2560 × 1440",
            isVirtualDisplay: false
        )

        let result = try await controller.startPreview(display: display, metadata: metadata)
        guard case .started(let sessionID) = result else {
            Issue.record("Expected preview start to succeed.")
            return
        }

        #expect(service.addCallCount == 1)
        #expect(controller.previewSession(for: sessionID)?.displayName == "Display 77")
        assertSnapshotMatchesService(controller: controller, service: service)
        #expect(controller.startingDisplayIDs.isEmpty)
    }

    @Test func startPreviewPublishesStartingDisplayIDWhileRequestIsInFlight() async throws {
        let service = MockCapturePreviewService()
        let gate = CaptureControllerAsyncGate()
        let expectedSessionID = UUID()
        let lifecycleService = CaptureControllerLifecycleSpy(capturePreviewService: service)
        lifecycleService.startPreviewHandler = { _, _ in
            await gate.wait()
            return .started(expectedSessionID)
        }
        let controller = CaptureController(
            capturePreviewService: service,
            capturePreviewLifecycleService: lifecycleService
        )
        let display = CaptureControllerMockSCDisplay.make(displayID: 781, width: 1920, height: 1080)
        let metadata = CapturePreviewDisplayMetadata(
            displayName: "Display 781",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let task = Task { @MainActor in
            try await controller.startPreview(display: display, metadata: metadata)
        }

        #expect(await waitForCaptureControllerGate(gate, count: 1))
        #expect(controller.startingDisplayIDs == [display.displayID])
        #expect(controller.isStarting(displayID: display.displayID))

        await gate.releaseOne()
        let outcome = try await task.value
        guard case .started(let sessionID) = outcome else {
            Issue.record("Expected preview start to succeed.")
            return
        }

        #expect(sessionID == expectedSessionID)
        #expect(controller.startingDisplayIDs.isEmpty)
        #expect(controller.isStarting(displayID: display.displayID) == false)
    }

    @Test func duplicateStartPreviewCallsShareSameUnderlyingStartOutcome() async throws {
        let service = MockCapturePreviewService()
        let gate = CaptureControllerAsyncGate()
        let previewSession = CaptureControllerDummySession()
        let previewSubscription = DisplayPreviewSubscription(
            displayID: 785,
            resolutionText: "1920 × 1080",
            session: previewSession,
            cancelClosure: {}
        )
        let lifecycleService = CapturePreviewLifecycleService(
            capturePreviewService: service,
            acquirePreview: { _, _ in
                await gate.wait()
                return .started(previewSubscription)
            }
        )
        let controller = CaptureController(
            capturePreviewService: service,
            capturePreviewLifecycleService: lifecycleService
        )
        let display = CaptureControllerMockSCDisplay.make(displayID: 785, width: 1920, height: 1080)
        let metadata = CapturePreviewDisplayMetadata(
            displayName: "Display 785",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let firstTask = Task { @MainActor in
            try await controller.startPreview(display: display, metadata: metadata)
        }
        #expect(await waitForCaptureControllerGate(gate, count: 1))

        let secondTask = Task { @MainActor in
            try await controller.startPreview(display: display, metadata: metadata)
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + AsyncTestTimeouts.shortStabilityWindow
        var observedSecondAcquire = false
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await gate.currentWaitCount() > 1 {
                observedSecondAcquire = true
                break
            }
            await Task.yield()
        }

        #expect(observedSecondAcquire == false)
        #expect(controller.startingDisplayIDs == [display.displayID])

        await gate.releaseOne()

        let firstOutcome = try await firstTask.value
        let secondOutcome = try await secondTask.value
        guard
            case .started(let firstSessionID) = firstOutcome,
            case .started(let secondSessionID) = secondOutcome
        else {
            Issue.record("Expected both preview starts to succeed.")
            return
        }

        #expect(firstSessionID == secondSessionID)
        #expect(service.addCallCount == 1)
        #expect(controller.startingDisplayIDs.isEmpty)
    }

    @Test func cancellingOneWaitingStartPreviewCallKeepsObservedStartingStateUntilLastWaiterFinishes() async throws {
        let service = MockCapturePreviewService()
        let gate = CaptureControllerAsyncGate()
        let expectedSessionID = UUID()
        let lifecycleService = CaptureControllerLifecycleSpy(capturePreviewService: service)
        lifecycleService.startPreviewHandler = { _, _ in
            await gate.wait()
            try Task.checkCancellation()
            return .started(expectedSessionID)
        }
        let controller = CaptureController(
            capturePreviewService: service,
            capturePreviewLifecycleService: lifecycleService
        )
        let display = CaptureControllerMockSCDisplay.make(displayID: 786, width: 1920, height: 1080)
        let metadata = CapturePreviewDisplayMetadata(
            displayName: "Display 786",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let firstTask = Task { @MainActor in
            try await controller.startPreview(display: display, metadata: metadata)
        }
        let secondTask = Task { @MainActor in
            try await controller.startPreview(display: display, metadata: metadata)
        }

        #expect(await waitForCaptureControllerGate(gate, count: 2))
        #expect(controller.startingDisplayIDs == [display.displayID])

        firstTask.cancel()
        await gate.releaseOne()

        do {
            let outcome = try await firstTask.value
            Issue.record("Expected first preview start to be cancelled, got \(outcome).")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(controller.startingDisplayIDs == [display.displayID])
        #expect(controller.isStarting(displayID: display.displayID))

        await gate.releaseOne()
        let secondOutcome = try await secondTask.value
        guard case .started(let sessionID) = secondOutcome else {
            Issue.record("Expected second preview start to succeed.")
            return
        }

        #expect(sessionID == expectedSessionID)
        #expect(controller.startingDisplayIDs.isEmpty)
    }

    @Test func startPreviewClearsStartingDisplayIDAfterFailure() async {
        struct ControlledError: Error {}

        let service = MockCapturePreviewService()
        let lifecycleService = CaptureControllerLifecycleSpy(capturePreviewService: service)
        lifecycleService.startPreviewHandler = { _, _ in
            throw ControlledError()
        }
        let controller = CaptureController(
            capturePreviewService: service,
            capturePreviewLifecycleService: lifecycleService
        )
        let display = CaptureControllerMockSCDisplay.make(displayID: 782, width: 1920, height: 1080)
        let metadata = CapturePreviewDisplayMetadata(
            displayName: "Display 782",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        do {
            let outcome = try await controller.startPreview(display: display, metadata: metadata)
            Issue.record("Expected preview start to fail, got \(outcome).")
        } catch {
        }

        #expect(controller.startingDisplayIDs.isEmpty)
        #expect(controller.isStarting(displayID: display.displayID) == false)
    }

    @Test func startPreviewClearsStartingDisplayIDAfterCancellation() async {
        let service = MockCapturePreviewService()
        let gate = CaptureControllerAsyncGate()
        let lifecycleService = CaptureControllerLifecycleSpy(capturePreviewService: service)
        lifecycleService.startPreviewHandler = { _, _ in
            await gate.wait()
            try Task.checkCancellation()
            return .started(UUID())
        }
        let controller = CaptureController(
            capturePreviewService: service,
            capturePreviewLifecycleService: lifecycleService
        )
        let display = CaptureControllerMockSCDisplay.make(displayID: 783, width: 1920, height: 1080)
        let metadata = CapturePreviewDisplayMetadata(
            displayName: "Display 783",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let task = Task { @MainActor in
            try await controller.startPreview(display: display, metadata: metadata)
        }

        #expect(await waitForCaptureControllerGate(gate, count: 1))
        #expect(controller.startingDisplayIDs == [display.displayID])

        task.cancel()
        await gate.releaseOne()

        do {
            let outcome = try await task.value
            Issue.record("Expected preview start to be cancelled, got \(outcome).")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(controller.startingDisplayIDs.isEmpty)
    }

    @Test func startPreviewClearsStartingDisplayIDAfterInvalidation() async throws {
        let service = MockCapturePreviewService()
        let lifecycleService = CaptureControllerLifecycleSpy(capturePreviewService: service)
        lifecycleService.startPreviewHandler = { _, _ in .invalidated }
        let controller = CaptureController(
            capturePreviewService: service,
            capturePreviewLifecycleService: lifecycleService
        )
        let display = CaptureControllerMockSCDisplay.make(displayID: 784, width: 1920, height: 1080)
        let metadata = CapturePreviewDisplayMetadata(
            displayName: "Display 784",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let outcome = try await controller.startPreview(display: display, metadata: metadata)

        if case .invalidated = outcome {
        } else {
            Issue.record("Expected invalidated outcome.")
        }
        #expect(controller.startingDisplayIDs.isEmpty)
    }

    @Test func activatePreviewSessionRefreshesSnapshot() {
        let service = MockCapturePreviewService()
        let session = makeSession(id: UUID(), displayID: 88).session
        service.currentSessions = [session]
        let controller = CaptureController(capturePreviewService: service)

        controller.activatePreviewSession(id: session.id)

        guard let updated = controller.screenPreviewSessions.first else {
            Issue.record("Expected active session.")
            return
        }
        if case .active = updated.state {
        } else {
            Issue.record("Expected controller session to be active.")
        }
        #expect(service.updateStateCallCount == 1)
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func attachPreviewSinkTargetsRequestedSessionAndKeepsSnapshotAligned() {
        let service = MockCapturePreviewService()
        let first = makeSession(id: UUID(), displayID: 89)
        let second = makeSession(id: UUID(), displayID: 90)
        service.currentSessions = [first.session, second.session]
        let controller = CaptureController(capturePreviewService: service)
        let sink = CaptureControllerPreviewSink()

        controller.attachPreviewSink(sink, to: second.session.id)

        #expect(first.captureSession.attachedSinkCount == 0)
        #expect(second.captureSession.attachedSinkCount == 1)
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func setPreviewSessionCapturesCursorRefreshesSnapshot() async throws {
        let service = MockCapturePreviewService()
        let sessionRecord = makeSession(id: UUID(), displayID: 91)
        service.currentSessions = [sessionRecord.session]
        let controller = CaptureController(capturePreviewService: service)

        try await controller.setPreviewSessionCapturesCursor(
            id: sessionRecord.session.id,
            capturesCursor: true
        )

        #expect(controller.screenPreviewSessions.first?.capturesCursor == true)
        #expect(service.updateCapturesCursorCallCount == 1)
        #expect(sessionRecord.captureSession.cursorUpdateCount == 1)
        #expect(sessionRecord.captureSession.lastShowsCursor == true)
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func closePreviewSessionRefreshesSnapshot() {
        let service = MockCapturePreviewService()
        let session = makeSession(id: UUID(), displayID: 92).session
        service.currentSessions = [session]
        let controller = CaptureController(capturePreviewService: service)

        controller.closePreviewSession(id: session.id)

        #expect(controller.screenPreviewSessions.isEmpty)
        #expect(service.removeCallCount == 1)
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func removePreviewSessionsFiltersByDisplayID() {
        let service = MockCapturePreviewService()
        let first = makeSession(id: UUID(), displayID: 93).session
        let second = makeSession(id: UUID(), displayID: 94).session
        service.currentSessions = [first, second]
        let lifecycleService = CaptureControllerLifecycleSpy(capturePreviewService: service)
        let controller = CaptureController(
            capturePreviewService: service,
            capturePreviewLifecycleService: lifecycleService
        )
        controller.installStartingDisplayIDsForTesting([93])

        controller.removePreviewSessions(displayID: 93)

        #expect(controller.screenPreviewSessions.map(\.displayID) == [94])
        #expect(controller.startingDisplayIDs.isEmpty)
        #expect(lifecycleService.removeByDisplayCallCount == 1)
        #expect(lifecycleService.removedDisplayIDs == [93])
        #expect(service.removeByDisplayCallCount == 1)
        #expect(service.removedDisplayIDs == [93])
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func unknownLifecycleMutationRequestsKeepControllerSnapshotStable() async throws {
        let service = MockCapturePreviewService()
        let first = makeSession(id: UUID(), displayID: 101)
        let second = makeSession(id: UUID(), displayID: 102)
        service.currentSessions = [first.session, second.session]
        let controller = CaptureController(capturePreviewService: service)
        let initialSignature = snapshotSignature(controller.screenPreviewSessions)
        let sink = CaptureControllerPreviewSink()

        controller.activatePreviewSession(id: UUID())
        #expect(snapshotSignature(controller.screenPreviewSessions) == initialSignature)
        #expect(service.updateStateCallCount == 0)
        assertSnapshotMatchesService(controller: controller, service: service)

        controller.attachPreviewSink(sink, to: UUID())
        #expect(snapshotSignature(controller.screenPreviewSessions) == initialSignature)
        #expect(first.captureSession.attachedSinkCount == 0)
        #expect(second.captureSession.attachedSinkCount == 0)
        assertSnapshotMatchesService(controller: controller, service: service)

        try await controller.setPreviewSessionCapturesCursor(id: UUID(), capturesCursor: true)
        #expect(snapshotSignature(controller.screenPreviewSessions) == initialSignature)
        #expect(service.updateCapturesCursorCallCount == 0)
        assertSnapshotMatchesService(controller: controller, service: service)

        controller.closePreviewSession(id: UUID())
        #expect(snapshotSignature(controller.screenPreviewSessions) == initialSignature)
        #expect(service.removeCallCount == 0)
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    private func makeSession(
        id: UUID,
        displayID: CGDirectDisplayID
    ) -> (session: ScreenPreviewSession, captureSession: CaptureControllerDummySession) {
        let captureSession = CaptureControllerDummySession()
        let session = ScreenPreviewSession(
            id: id,
            displayID: displayID,
            displayName: "Display \(displayID)",
            resolutionText: "1920 x 1080",
            isVirtualDisplay: false,
            previewSubscription: DisplayPreviewSubscription(
                displayID: displayID,
                resolutionText: "1920 x 1080",
                session: captureSession,
                cancelClosure: {},
                setShowsCursorClosure: { showsCursor in
                    try await captureSession.setDemand(
                        DisplayCaptureDemandSnapshot(
                            previewShowsCursor: showsCursor,
                            performanceMode: .automatic
                        )
                    )
                }
            ),
            capturesCursor: false,
            state: .starting
        )
        return (session, captureSession)
    }

    private func assertSnapshotMatchesService(
        controller: CaptureController,
        service: MockCapturePreviewService
    ) {
        #expect(snapshotSignature(controller.screenPreviewSessions) == snapshotSignature(service.currentSessions))
    }

    private func snapshotSignature(_ sessions: [ScreenPreviewSession]) -> [SessionSnapshot] {
        sessions.map { session in
            let stateLabel: String
            switch session.state {
            case .starting:
                stateLabel = "starting"
            case .active:
                stateLabel = "active"
            }
            return SessionSnapshot(
                id: session.id,
                displayID: session.displayID,
                capturesCursor: session.capturesCursor,
                state: stateLabel
            )
        }
    }
}

private func waitForCaptureControllerGate(
    _ gate: CaptureControllerAsyncGate,
    count: Int,
    timeoutNanoseconds: UInt64 = AsyncTestTimeouts.defaultAsyncAssertion,
    pollNanoseconds: UInt64 = 10_000_000
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await gate.currentWaitCount() >= count {
            return true
        }
        try? await Task.sleep(for: .nanoseconds(pollNanoseconds))
    }
    return await gate.currentWaitCount() >= count
}
