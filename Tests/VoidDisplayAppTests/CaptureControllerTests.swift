@testable import VoidDisplayApp
@testable import VoidDisplayApp
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayCapture
@testable import VoidDisplaySharing
@testable import VoidDisplayObservability
@testable import VoidDisplaySupport
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import Testing

private final class CaptureControllerDummySession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let sessionHub = WebRTCSessionHub()
    nonisolated var shareFrameConsumer: any DisplayShareFrameConsumer { sessionHub }

    nonisolated(unsafe) var attachedSinkCount = 0
    nonisolated(unsafe) var detachedSinkCount = 0
    nonisolated(unsafe) var cursorUpdateCount = 0
    nonisolated(unsafe) var lastShowsCursor: Bool?

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
        attachedSinkCount += 1
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
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
    nonisolated func submitFrame(_ sampleBuffer: CMSampleBuffer) {
        _ = sampleBuffer
    }
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
private final class CaptureControllerLifecycleSpy: CaptureMonitoringLifecycleServiceProtocol {
    typealias StartMonitoringHandler = @MainActor (
        SCDisplay,
        CaptureMonitoringDisplayMetadata
    ) async throws -> DisplayStartOutcome<UUID>

    private let base: CaptureMonitoringLifecycleService
    private let eventRecorder: ((String) -> Void)?
    var startMonitoringHandler: StartMonitoringHandler?

    private(set) var removeByDisplayCallCount = 0
    private(set) var removedDisplayIDs: [CGDirectDisplayID] = []

    init(
        captureMonitoringService: any CaptureMonitoringServiceProtocol,
        eventRecorder: ((String) -> Void)? = nil
    ) {
        self.base = CaptureMonitoringLifecycleService(captureMonitoringService: captureMonitoringService)
        self.eventRecorder = eventRecorder
    }

    func isStarting(displayID: CGDirectDisplayID) -> Bool {
        base.isStarting(displayID: displayID)
    }

    func startMonitoring(
        display: SCDisplay,
        metadata: CaptureMonitoringDisplayMetadata
    ) async throws -> DisplayStartOutcome<UUID> {
        if let startMonitoringHandler {
            return try await startMonitoringHandler(display, metadata)
        }
        return try await base.startMonitoring(display: display, metadata: metadata)
    }

    func activateMonitoringSession(id: UUID) {
        base.activateMonitoringSession(id: id)
    }

    func attachPreviewSink(_ sink: any DisplayPreviewSink, to id: UUID) {
        base.attachPreviewSink(sink, to: id)
    }

    func setMonitoringSessionCapturesCursor(
        id: UUID,
        capturesCursor: Bool
    ) async throws {
        try await base.setMonitoringSessionCapturesCursor(id: id, capturesCursor: capturesCursor)
    }

    func closeMonitoringSession(id: UUID) {
        base.closeMonitoringSession(id: id)
    }

    func removeMonitoringSessions(displayID: CGDirectDisplayID) {
        removeByDisplayCallCount += 1
        removedDisplayIDs.append(displayID)
        eventRecorder?("removeMonitoring:\(displayID)")
        base.removeMonitoringSessions(displayID: displayID)
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
        let service = MockCaptureMonitoringService()
        let existingSession = makeSession(id: UUID(), displayID: 66).session
        service.currentSessions = [existingSession]

        let controller = CaptureController(captureMonitoringService: service)

        #expect(controller.screenCaptureSessions.map(\.id) == [existingSession.id])
    }

    @Test func startMonitoringRefreshesSnapshotFromLifecycleService() async throws {
        let service = MockCaptureMonitoringService()
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
        let lifecycleService = CaptureMonitoringLifecycleService(
            captureMonitoringService: service,
            acquirePreview: { _, _ in .started(subscription) }
        )
        let controller = CaptureController(
            captureMonitoringService: service,
            captureMonitoringLifecycleService: lifecycleService
        )
        let display = CaptureControllerMockSCDisplay.make(displayID: 77, width: 2560, height: 1440)
        let metadata = CaptureMonitoringDisplayMetadata(
            displayName: "Display 77",
            resolutionText: "2560 × 1440",
            isVirtualDisplay: false
        )

        let result = try await controller.startMonitoring(display: display, metadata: metadata)
        guard case .started(let sessionID) = result else {
            Issue.record("Expected monitoring start to succeed.")
            return
        }

        #expect(service.addCallCount == 1)
        #expect(controller.monitoringSession(for: sessionID)?.displayName == "Display 77")
        assertSnapshotMatchesService(controller: controller, service: service)
        #expect(controller.startingDisplayIDs.isEmpty)
    }

    @Test func startMonitoringPublishesStartingDisplayIDWhileRequestIsInFlight() async throws {
        let service = MockCaptureMonitoringService()
        let gate = CaptureControllerAsyncGate()
        let expectedSessionID = UUID()
        let lifecycleService = CaptureControllerLifecycleSpy(captureMonitoringService: service)
        lifecycleService.startMonitoringHandler = { _, _ in
            await gate.wait()
            return .started(expectedSessionID)
        }
        let controller = CaptureController(
            captureMonitoringService: service,
            captureMonitoringLifecycleService: lifecycleService
        )
        let display = CaptureControllerMockSCDisplay.make(displayID: 781, width: 1920, height: 1080)
        let metadata = CaptureMonitoringDisplayMetadata(
            displayName: "Display 781",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let task = Task { @MainActor in
            try await controller.startMonitoring(display: display, metadata: metadata)
        }

        #expect(await waitForCaptureControllerGate(gate, count: 1))
        #expect(controller.startingDisplayIDs == [display.displayID])
        #expect(controller.isStarting(displayID: display.displayID))

        await gate.releaseOne()
        let outcome = try await task.value
        guard case .started(let sessionID) = outcome else {
            Issue.record("Expected monitoring start to succeed.")
            return
        }

        #expect(sessionID == expectedSessionID)
        #expect(controller.startingDisplayIDs.isEmpty)
        #expect(controller.isStarting(displayID: display.displayID) == false)
    }

    @Test func duplicateStartMonitoringCallsShareSameUnderlyingStartOutcome() async throws {
        let service = MockCaptureMonitoringService()
        let gate = CaptureControllerAsyncGate()
        let previewSession = CaptureControllerDummySession()
        let previewSubscription = DisplayPreviewSubscription(
            displayID: 785,
            resolutionText: "1920 × 1080",
            session: previewSession,
            cancelClosure: {}
        )
        let lifecycleService = CaptureMonitoringLifecycleService(
            captureMonitoringService: service,
            acquirePreview: { _, _ in
                await gate.wait()
                return .started(previewSubscription)
            }
        )
        let controller = CaptureController(
            captureMonitoringService: service,
            captureMonitoringLifecycleService: lifecycleService
        )
        let display = CaptureControllerMockSCDisplay.make(displayID: 785, width: 1920, height: 1080)
        let metadata = CaptureMonitoringDisplayMetadata(
            displayName: "Display 785",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let firstTask = Task { @MainActor in
            try await controller.startMonitoring(display: display, metadata: metadata)
        }
        #expect(await waitForCaptureControllerGate(gate, count: 1))

        let secondTask = Task { @MainActor in
            try await controller.startMonitoring(display: display, metadata: metadata)
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
            Issue.record("Expected both monitoring starts to succeed.")
            return
        }

        #expect(firstSessionID == secondSessionID)
        #expect(service.addCallCount == 1)
        #expect(controller.startingDisplayIDs.isEmpty)
    }

    @Test func cancellingOneWaitingStartMonitoringCallKeepsObservedStartingStateUntilLastWaiterFinishes() async throws {
        let service = MockCaptureMonitoringService()
        let gate = CaptureControllerAsyncGate()
        let expectedSessionID = UUID()
        let lifecycleService = CaptureControllerLifecycleSpy(captureMonitoringService: service)
        lifecycleService.startMonitoringHandler = { _, _ in
            await gate.wait()
            try Task.checkCancellation()
            return .started(expectedSessionID)
        }
        let controller = CaptureController(
            captureMonitoringService: service,
            captureMonitoringLifecycleService: lifecycleService
        )
        let display = CaptureControllerMockSCDisplay.make(displayID: 786, width: 1920, height: 1080)
        let metadata = CaptureMonitoringDisplayMetadata(
            displayName: "Display 786",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let firstTask = Task { @MainActor in
            try await controller.startMonitoring(display: display, metadata: metadata)
        }
        let secondTask = Task { @MainActor in
            try await controller.startMonitoring(display: display, metadata: metadata)
        }

        #expect(await waitForCaptureControllerGate(gate, count: 2))
        #expect(controller.startingDisplayIDs == [display.displayID])

        firstTask.cancel()
        await gate.releaseOne()

        do {
            _ = try await firstTask.value
            Issue.record("Expected first monitoring start to be cancelled.")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(controller.startingDisplayIDs == [display.displayID])
        #expect(controller.isStarting(displayID: display.displayID))

        await gate.releaseOne()
        let secondOutcome = try await secondTask.value
        guard case .started(let sessionID) = secondOutcome else {
            Issue.record("Expected second monitoring start to succeed.")
            return
        }

        #expect(sessionID == expectedSessionID)
        #expect(controller.startingDisplayIDs.isEmpty)
    }

    @Test func startMonitoringClearsStartingDisplayIDAfterFailure() async {
        struct ControlledError: Error {}

        let service = MockCaptureMonitoringService()
        let lifecycleService = CaptureControllerLifecycleSpy(captureMonitoringService: service)
        lifecycleService.startMonitoringHandler = { _, _ in
            throw ControlledError()
        }
        let controller = CaptureController(
            captureMonitoringService: service,
            captureMonitoringLifecycleService: lifecycleService
        )
        let display = CaptureControllerMockSCDisplay.make(displayID: 782, width: 1920, height: 1080)
        let metadata = CaptureMonitoringDisplayMetadata(
            displayName: "Display 782",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        do {
            _ = try await controller.startMonitoring(display: display, metadata: metadata)
            Issue.record("Expected monitoring start to fail.")
        } catch {
        }

        #expect(controller.startingDisplayIDs.isEmpty)
        #expect(controller.isStarting(displayID: display.displayID) == false)
    }

    @Test func startMonitoringClearsStartingDisplayIDAfterCancellation() async {
        let service = MockCaptureMonitoringService()
        let gate = CaptureControllerAsyncGate()
        let lifecycleService = CaptureControllerLifecycleSpy(captureMonitoringService: service)
        lifecycleService.startMonitoringHandler = { _, _ in
            await gate.wait()
            try Task.checkCancellation()
            return .started(UUID())
        }
        let controller = CaptureController(
            captureMonitoringService: service,
            captureMonitoringLifecycleService: lifecycleService
        )
        let display = CaptureControllerMockSCDisplay.make(displayID: 783, width: 1920, height: 1080)
        let metadata = CaptureMonitoringDisplayMetadata(
            displayName: "Display 783",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let task = Task { @MainActor in
            try await controller.startMonitoring(display: display, metadata: metadata)
        }

        #expect(await waitForCaptureControllerGate(gate, count: 1))
        #expect(controller.startingDisplayIDs == [display.displayID])

        task.cancel()
        await gate.releaseOne()

        do {
            _ = try await task.value
            Issue.record("Expected monitoring start to be cancelled.")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(controller.startingDisplayIDs.isEmpty)
    }

    @Test func startMonitoringClearsStartingDisplayIDAfterInvalidation() async throws {
        let service = MockCaptureMonitoringService()
        let lifecycleService = CaptureControllerLifecycleSpy(captureMonitoringService: service)
        lifecycleService.startMonitoringHandler = { _, _ in .invalidated }
        let controller = CaptureController(
            captureMonitoringService: service,
            captureMonitoringLifecycleService: lifecycleService
        )
        let display = CaptureControllerMockSCDisplay.make(displayID: 784, width: 1920, height: 1080)
        let metadata = CaptureMonitoringDisplayMetadata(
            displayName: "Display 784",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let outcome = try await controller.startMonitoring(display: display, metadata: metadata)

        if case .invalidated = outcome {
        } else {
            Issue.record("Expected invalidated outcome.")
        }
        #expect(controller.startingDisplayIDs.isEmpty)
    }

    @Test func activateMonitoringSessionRefreshesSnapshot() {
        let service = MockCaptureMonitoringService()
        let session = makeSession(id: UUID(), displayID: 88).session
        service.currentSessions = [session]
        let controller = CaptureController(captureMonitoringService: service)

        controller.activateMonitoringSession(id: session.id)

        guard let updated = controller.screenCaptureSessions.first else {
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
        let service = MockCaptureMonitoringService()
        let first = makeSession(id: UUID(), displayID: 89)
        let second = makeSession(id: UUID(), displayID: 90)
        service.currentSessions = [first.session, second.session]
        let controller = CaptureController(captureMonitoringService: service)
        let sink = CaptureControllerPreviewSink()

        controller.attachPreviewSink(sink, to: second.session.id)

        #expect(first.captureSession.attachedSinkCount == 0)
        #expect(second.captureSession.attachedSinkCount == 1)
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func setMonitoringSessionCapturesCursorRefreshesSnapshot() async throws {
        let service = MockCaptureMonitoringService()
        let sessionRecord = makeSession(id: UUID(), displayID: 91)
        service.currentSessions = [sessionRecord.session]
        let controller = CaptureController(captureMonitoringService: service)

        try await controller.setMonitoringSessionCapturesCursor(
            id: sessionRecord.session.id,
            capturesCursor: true
        )

        #expect(controller.screenCaptureSessions.first?.capturesCursor == true)
        #expect(service.updateCapturesCursorCallCount == 1)
        #expect(sessionRecord.captureSession.cursorUpdateCount == 1)
        #expect(sessionRecord.captureSession.lastShowsCursor == true)
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func closeMonitoringSessionRefreshesSnapshot() {
        let service = MockCaptureMonitoringService()
        let session = makeSession(id: UUID(), displayID: 92).session
        service.currentSessions = [session]
        let controller = CaptureController(captureMonitoringService: service)

        controller.closeMonitoringSession(id: session.id)

        #expect(controller.screenCaptureSessions.isEmpty)
        #expect(service.removeCallCount == 1)
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func removeMonitoringSessionsFiltersByDisplayID() {
        let service = MockCaptureMonitoringService()
        let first = makeSession(id: UUID(), displayID: 93).session
        let second = makeSession(id: UUID(), displayID: 94).session
        service.currentSessions = [first, second]
        let lifecycleService = CaptureControllerLifecycleSpy(captureMonitoringService: service)
        let controller = CaptureController(
            captureMonitoringService: service,
            captureMonitoringLifecycleService: lifecycleService
        )
        controller.installStartingDisplayIDsForTesting([93])

        controller.removeMonitoringSessions(displayID: 93)

        #expect(controller.screenCaptureSessions.map(\.displayID) == [94])
        #expect(controller.startingDisplayIDs.isEmpty)
        #expect(lifecycleService.removeByDisplayCallCount == 1)
        #expect(lifecycleService.removedDisplayIDs == [93])
        #expect(service.removeByDisplayCallCount == 1)
        #expect(service.removedDisplayIDs == [93])
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func unknownLifecycleMutationRequestsKeepControllerSnapshotStable() async throws {
        let service = MockCaptureMonitoringService()
        let first = makeSession(id: UUID(), displayID: 101)
        let second = makeSession(id: UUID(), displayID: 102)
        service.currentSessions = [first.session, second.session]
        let controller = CaptureController(captureMonitoringService: service)
        let initialSignature = snapshotSignature(controller.screenCaptureSessions)
        let sink = CaptureControllerPreviewSink()

        controller.activateMonitoringSession(id: UUID())
        #expect(snapshotSignature(controller.screenCaptureSessions) == initialSignature)
        #expect(service.updateStateCallCount == 0)
        assertSnapshotMatchesService(controller: controller, service: service)

        controller.attachPreviewSink(sink, to: UUID())
        #expect(snapshotSignature(controller.screenCaptureSessions) == initialSignature)
        #expect(first.captureSession.attachedSinkCount == 0)
        #expect(second.captureSession.attachedSinkCount == 0)
        assertSnapshotMatchesService(controller: controller, service: service)

        try await controller.setMonitoringSessionCapturesCursor(id: UUID(), capturesCursor: true)
        #expect(snapshotSignature(controller.screenCaptureSessions) == initialSignature)
        #expect(service.updateCapturesCursorCallCount == 0)
        assertSnapshotMatchesService(controller: controller, service: service)

        controller.closeMonitoringSession(id: UUID())
        #expect(snapshotSignature(controller.screenCaptureSessions) == initialSignature)
        #expect(service.removeCallCount == 0)
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func stopDependentStreamsBeforeRebuildStopsSharingAndMonitoring() {
        let service = MockCaptureMonitoringService()
        let session = makeSession(id: UUID(), displayID: 123).session
        service.currentSessions = [session]
        var eventLog: [String] = []
        let sharingService = MockSharingService()
        sharingService.activeSharingDisplayIDs = [123]
        sharingService.hasAnyActiveSharing = true
        sharingService.onStopSharing = { displayID in
            eventLog.append("stopSharing:\(displayID)")
        }
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: SharingPortPreferences(defaults: UserDefaults(suiteName: "CaptureControllerTests")!)
        )
        let lifecycleService = CaptureControllerLifecycleSpy(
            captureMonitoringService: service,
            eventRecorder: { eventLog.append($0) }
        )
        let controller = CaptureController(
            captureMonitoringService: service,
            captureMonitoringLifecycleService: lifecycleService
        )

        controller.stopDependentStreamsBeforeRebuild(
            displayID: 123,
            sharingController: sharingController
        )

        #expect(eventLog == ["stopSharing:123", "removeMonitoring:123"])
        #expect(sharingService.stopSharingCallCount == 1)
        #expect(lifecycleService.removeByDisplayCallCount == 1)
        #expect(service.removeByDisplayCallCount == 1)
        #expect(controller.screenCaptureSessions.isEmpty)
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    @Test func stopDependentStreamsBeforeRebuildDoesNotStopSharingWhenDisplayIsNotShared() {
        let service = MockCaptureMonitoringService()
        let session = makeSession(id: UUID(), displayID: 124).session
        service.currentSessions = [session]
        var eventLog: [String] = []
        let sharingService = MockSharingService()
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: SharingPortPreferences(defaults: UserDefaults(suiteName: "CaptureControllerTestsNoShare")!)
        )
        let lifecycleService = CaptureControllerLifecycleSpy(
            captureMonitoringService: service,
            eventRecorder: { eventLog.append($0) }
        )
        let controller = CaptureController(
            captureMonitoringService: service,
            captureMonitoringLifecycleService: lifecycleService
        )

        controller.stopDependentStreamsBeforeRebuild(
            displayID: 124,
            sharingController: sharingController
        )

        #expect(eventLog == ["removeMonitoring:124"])
        #expect(sharingService.stopSharingCallCount == 0)
        #expect(lifecycleService.removeByDisplayCallCount == 1)
        #expect(service.removeByDisplayCallCount == 1)
        #expect(controller.screenCaptureSessions.isEmpty)
        assertSnapshotMatchesService(controller: controller, service: service)
    }

    private func makeSession(
        id: UUID,
        displayID: CGDirectDisplayID
    ) -> (session: ScreenMonitoringSession, captureSession: CaptureControllerDummySession) {
        let captureSession = CaptureControllerDummySession()
        let session = ScreenMonitoringSession(
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
        service: MockCaptureMonitoringService
    ) {
        #expect(snapshotSignature(controller.screenCaptureSessions) == snapshotSignature(service.currentSessions))
    }

    private func snapshotSignature(_ sessions: [ScreenMonitoringSession]) -> [SessionSnapshot] {
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
