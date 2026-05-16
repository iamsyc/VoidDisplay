@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import Testing

private final class CapturePreviewLifecycleDummySession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let shareFrameConsumer: any DisplayShareFrameConsumer = TestDisplayShareFrameConsumer()

    nonisolated(unsafe) var attachedSinkCount = 0
    nonisolated(unsafe) var detachedSinkCount = 0
    nonisolated(unsafe) var cursorUpdateCount = 0
    nonisolated(unsafe) var lastShowsCursor: Bool?
    nonisolated(unsafe) var cursorUpdateError: Error?

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
        if let cursorUpdateError {
            throw cursorUpdateError
        }
    }

    nonisolated func stop() async {}
}

private final class CapturePreviewLifecyclePreviewSink: DisplayPreviewSink, @unchecked Sendable {
    nonisolated func submitFrame(_ _: CMSampleBuffer) {}
}

private final class CapturePreviewLifecycleCancelCounter: @unchecked Sendable {
    nonisolated(unsafe) var value = 0
}

private final class CapturePreviewLifecycleMockSCDisplayBox: NSObject {
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

private enum CapturePreviewLifecycleMockSCDisplay {
    static func make(displayID: CGDirectDisplayID, width: Int, height: Int) -> SCDisplay {
        let box = CapturePreviewLifecycleMockSCDisplayBox(
            displayID: displayID,
            width: width,
            height: height
        )
        return unsafeBitCast(box, to: SCDisplay.self)
    }
}

private struct CapturePreviewLifecycleControlledError: Error, Equatable {}

private actor CapturePreviewLifecycleAcquirePreviewGate {
    enum Outcome: Sendable {
        case success(DisplayPreviewSubscription)
        case failure(any Error & Sendable)
    }

    private struct PendingCall {
        let outcome: Outcome
        let continuation: CheckedContinuation<Outcome, Never>
    }

    private let scriptedOutcomes: [Outcome]
    private var callCount = 0
    private var pendingCalls: [Int: PendingCall] = [:]

    init(scriptedOutcomes: [Outcome]) {
        self.scriptedOutcomes = scriptedOutcomes
    }

    func nextOutcome() async -> Outcome {
        callCount += 1
        let callIndex = callCount
        let outcome = scriptedOutcomes.indices.contains(callIndex - 1)
            ? scriptedOutcomes[callIndex - 1]
            : scriptedOutcomes.last!
        return await withCheckedContinuation { continuation in
            pendingCalls[callIndex] = PendingCall(
                outcome: outcome,
                continuation: continuation
            )
        }
    }

    func release(call callIndex: Int) {
        guard let pending = pendingCalls.removeValue(forKey: callIndex) else { return }
        pending.continuation.resume(returning: pending.outcome)
    }

    func currentCallCount() -> Int {
        callCount
    }
}

@Suite(.serialized)
@MainActor
struct CapturePreviewLifecycleServiceTests {
    @Test func startPreviewCreatesSessionAndReturnsID() async throws {
        let service = MockCapturePreviewService()
        let previewRecord = makePreview(displayID: 701)
        let lifecycle = CapturePreviewLifecycleService(
            capturePreviewService: service,
            acquirePreview: { _, _ in .started(previewRecord.subscription) }
        )
        let display = CapturePreviewLifecycleMockSCDisplay.make(
            displayID: 701,
            width: 1920,
            height: 1080
        )
        let metadata = CapturePreviewDisplayMetadata(
            displayName: "Studio Display",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let outcome = try await lifecycle.startPreview(display: display, metadata: metadata)
        let sessionID: UUID
        switch outcome {
        case .started(let id):
            sessionID = id
        case .invalidated:
            Issue.record("Expected preview start to succeed.")
            return
        }

        #expect(service.addCallCount == 1)
        #expect(service.currentSessions.count == 1)
        #expect(service.currentSessions.first?.id == sessionID)
        #expect(service.currentSessions.first?.displayName == "Studio Display")
        #expect(service.currentSessions.first?.resolutionText == "1920 × 1080")
        #expect(service.currentSessions.first?.isVirtualDisplay == false)
    }

    @Test func startPreviewReusesExistingSessionIDForSameDisplay() async throws {
        let service = MockCapturePreviewService()
        let existing = makeSession(id: UUID(), displayID: 702)
        service.currentSessions = [existing.session]
        var acquirePreviewCallCount = 0
        let lifecycle = CapturePreviewLifecycleService(
            capturePreviewService: service,
            acquirePreview: { _, _ in
                acquirePreviewCallCount += 1
                return .started(makePreview(displayID: 702).subscription)
            }
        )
        let display = CapturePreviewLifecycleMockSCDisplay.make(
            displayID: 702,
            width: 1920,
            height: 1080
        )

        let outcome = try await lifecycle.startPreview(
            display: display,
            metadata: .init(
                displayName: "Ignored",
                resolutionText: "1920 × 1080",
                isVirtualDisplay: false
            )
        )
        let sessionID: UUID
        switch outcome {
        case .started(let id):
            sessionID = id
        case .invalidated:
            Issue.record("Expected preview start to reuse existing session.")
            return
        }

        #expect(sessionID == existing.session.id)
        #expect(acquirePreviewCallCount == 0)
        #expect(service.addCallCount == 0)
        #expect(service.currentSessions.count == 1)
    }

    @Test func startPreviewUsesInjectedAcquirePreview() async throws {
        let service = MockCapturePreviewService()
        var usedInjectedAcquirePreview = false
        let lifecycle = CapturePreviewLifecycleService(
            capturePreviewService: service,
            acquirePreview: { _, _ in
                usedInjectedAcquirePreview = true
                return .started(makePreview(displayID: 703).subscription)
            }
        )
        let display = CapturePreviewLifecycleMockSCDisplay.make(
            displayID: 703,
            width: 2560,
            height: 1440
        )

        _ = try await lifecycle.startPreview(
            display: display,
            metadata: .init(
                displayName: "Preview Source",
                resolutionText: "2560 × 1440",
                isVirtualDisplay: true
            )
        )

        #expect(usedInjectedAcquirePreview)
    }

    @Test func concurrentStartPreviewForSameDisplayCreatesOneSessionAndOnePreviewAcquire() async throws {
        let service = MockCapturePreviewService()
        let preview = makePreview(displayID: 712)
        let gate = CapturePreviewLifecycleAcquirePreviewGate(
            scriptedOutcomes: [.success(preview.subscription)]
        )
        let lifecycle = CapturePreviewLifecycleService(
            capturePreviewService: service,
            acquirePreview: { _, _ in
                switch await gate.nextOutcome() {
                case .success(let subscription):
                    return .started(subscription)
                case .failure(let error):
                    throw error
                }
            }
        )
        let display = CapturePreviewLifecycleMockSCDisplay.make(
            displayID: 712,
            width: 1920,
            height: 1080
        )
        let metadata = CapturePreviewDisplayMetadata(
            displayName: "Shared Display",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let firstTask = Task { @MainActor in
            try await lifecycle.startPreview(display: display, metadata: metadata)
        }
        #expect(await waitForAcquirePreviewCall(gate, count: 1))

        let secondTask = Task { @MainActor in
            try await lifecycle.startPreview(display: display, metadata: metadata)
        }
        let stayedSingleAcquire = await staysTrue {
            await gate.currentCallCount() == 1
        }
        #expect(stayedSingleAcquire)

        await gate.release(call: 1)
        let firstOutcome = try await firstTask.value
        let secondOutcome = try await secondTask.value
        let firstID: UUID
        let secondID: UUID
        switch firstOutcome {
        case .started(let id):
            firstID = id
        case .invalidated:
            Issue.record("Expected first preview start to succeed.")
            return
        }
        switch secondOutcome {
        case .started(let id):
            secondID = id
        case .invalidated:
            Issue.record("Expected second preview start to reuse the same start outcome.")
            return
        }

        #expect(firstID == secondID)
        #expect(service.addCallCount == 1)
        #expect(service.currentSessions.count == 1)
        #expect(service.currentSessions.first?.displayID == 712)
    }

    @Test func attachPreviewSinkTargetsRequestedSessionOnly() {
        let service = MockCapturePreviewService()
        let first = makeSession(id: UUID(), displayID: 704)
        let second = makeSession(id: UUID(), displayID: 705)
        service.currentSessions = [first.session, second.session]
        let lifecycle = CapturePreviewLifecycleService(capturePreviewService: service)
        let sink = CapturePreviewLifecyclePreviewSink()

        lifecycle.attachPreviewSink(sink, to: second.session.id)

        #expect(first.captureSession.attachedSinkCount == 0)
        #expect(second.captureSession.attachedSinkCount == 1)
    }

    @Test func activatePreviewSessionPromotesOnlyRequestedSession() {
        let service = MockCapturePreviewService()
        let first = makeSession(id: UUID(), displayID: 706)
        let second = makeSession(id: UUID(), displayID: 707)
        service.currentSessions = [first.session, second.session]
        let lifecycle = CapturePreviewLifecycleService(capturePreviewService: service)

        lifecycle.activatePreviewSession(id: second.session.id)

        #expect(service.currentSessions.first(where: { $0.id == first.session.id })?.state == .starting)
        #expect(service.currentSessions.first(where: { $0.id == second.session.id })?.state == .active)
        #expect(service.updateStateCallCount == 1)
    }

    @Test func setPreviewSessionCapturesCursorWritesBackOnlyAfterPreviewUpdateSucceeds() async throws {
        let service = MockCapturePreviewService()
        let record = makeSession(id: UUID(), displayID: 708)
        service.currentSessions = [record.session]
        let lifecycle = CapturePreviewLifecycleService(capturePreviewService: service)

        try await lifecycle.setPreviewSessionCapturesCursor(
            id: record.session.id,
            capturesCursor: true
        )

        #expect(record.captureSession.cursorUpdateCount == 1)
        #expect(record.captureSession.lastShowsCursor == true)
        #expect(service.updateCapturesCursorCallCount == 1)
        #expect(service.currentSessions.first?.capturesCursor == true)
    }

    @Test func setPreviewSessionCapturesCursorDoesNotWriteBackWhenPreviewUpdateFails() async {
        let service = MockCapturePreviewService()
        let record = makeSession(id: UUID(), displayID: 709)
        record.captureSession.cursorUpdateError = CapturePreviewLifecycleControlledError()
        service.currentSessions = [record.session]
        let lifecycle = CapturePreviewLifecycleService(capturePreviewService: service)

        await #expect(throws: CapturePreviewLifecycleControlledError.self) {
            try await lifecycle.setPreviewSessionCapturesCursor(
                id: record.session.id,
                capturesCursor: true
            )
        }

        #expect(record.captureSession.cursorUpdateCount == 1)
        #expect(service.updateCapturesCursorCallCount == 0)
        #expect(service.currentSessions.first?.capturesCursor == false)
    }

    @Test func closePreviewSessionUsesRemovePathOnly() {
        let service = MockCapturePreviewService()
        let record = makeSession(id: UUID(), displayID: 710)
        service.currentSessions = [record.session]
        let lifecycle = CapturePreviewLifecycleService(capturePreviewService: service)

        lifecycle.closePreviewSession(id: record.session.id)

        #expect(service.removeCallCount == 1)
        #expect(record.cancelCounter.value == 0)
        #expect(service.currentSessions.isEmpty)
    }

    @Test func removePreviewSessionsRemovesSingleMatchingDisplaySession() {
        let record = makeSession(id: UUID(), displayID: 714)
        let service = CapturePreviewService(initialSessions: [record.session])
        let lifecycle = CapturePreviewLifecycleService(capturePreviewService: service)

        lifecycle.removePreviewSessions(displayID: 714)

        #expect(service.currentSessions.isEmpty)
        #expect(record.cancelCounter.value == 1)
    }

    @Test func removePreviewSessionsRemovesAllMatchingSessionsAndPreservesOtherDisplays() {
        let first = makeSession(id: UUID(), displayID: 715)
        let second = makeSession(id: UUID(), displayID: 715)
        let third = makeSession(id: UUID(), displayID: 716)
        let service = CapturePreviewService(initialSessions: [
            first.session,
            second.session,
            third.session
        ])
        let lifecycle = CapturePreviewLifecycleService(capturePreviewService: service)

        lifecycle.removePreviewSessions(displayID: 715)

        #expect(service.currentSessions.map(\.displayID) == [716])
        #expect(first.cancelCounter.value == 1)
        #expect(second.cancelCounter.value == 1)
        #expect(third.cancelCounter.value == 0)
    }

    @Test func removePreviewSessionsIgnoresUnknownDisplayID() {
        let first = makeSession(id: UUID(), displayID: 717)
        let second = makeSession(id: UUID(), displayID: 718)
        let service = CapturePreviewService(initialSessions: [first.session, second.session])
        let lifecycle = CapturePreviewLifecycleService(capturePreviewService: service)

        lifecycle.removePreviewSessions(displayID: 999)

        #expect(service.currentSessions.map(\.id) == [first.session.id, second.session.id])
        #expect(first.cancelCounter.value == 0)
        #expect(second.cancelCounter.value == 0)
    }

    @Test func failedInFlightStartClearsMutualExclusionAndAllowsRetry() async {
        let service = MockCapturePreviewService()
        let secondPreview = makePreview(displayID: 713)
        let gate = CapturePreviewLifecycleAcquirePreviewGate(
            scriptedOutcomes: [
                .failure(CapturePreviewLifecycleControlledError()),
                .success(secondPreview.subscription)
            ]
        )
        let lifecycle = CapturePreviewLifecycleService(
            capturePreviewService: service,
            acquirePreview: { _, _ in
                switch await gate.nextOutcome() {
                case .success(let subscription):
                    return .started(subscription)
                case .failure(let error):
                    throw error
                }
            }
        )
        let display = CapturePreviewLifecycleMockSCDisplay.make(
            displayID: 713,
            width: 1920,
            height: 1080
        )
        let metadata = CapturePreviewDisplayMetadata(
            displayName: "Retry Display",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let firstTask = Task { @MainActor in
            try await lifecycle.startPreview(display: display, metadata: metadata)
        }
        #expect(await waitForAcquirePreviewCall(gate, count: 1))
        await gate.release(call: 1)

        await #expect(throws: CapturePreviewLifecycleControlledError.self) {
            try await firstTask.value
        }

        let retryTask = Task { @MainActor in
            try await lifecycle.startPreview(display: display, metadata: metadata)
        }
        #expect(await waitForAcquirePreviewCall(gate, count: 2))
        await gate.release(call: 2)
        let retryOutcome = try? await retryTask.value
        let retryID: UUID?
        if case .some(.started(let id)) = retryOutcome {
            retryID = id
        } else {
            retryID = nil
        }

        #expect(retryID != nil)
        #expect(service.addCallCount == 1)
        #expect(service.currentSessions.count == 1)
        #expect(service.currentSessions.first?.displayID == 713)
    }

    @Test func removePreviewSessionsCancelsInFlightStartAndAllowsCleanRetry() async throws {
        let service = CapturePreviewService()
        let firstPreview = makePreview(displayID: 719)
        let secondPreview = makePreview(displayID: 719)
        let gate = CapturePreviewLifecycleAcquirePreviewGate(
            scriptedOutcomes: [
                .success(firstPreview.subscription),
                .success(secondPreview.subscription)
            ]
        )
        let lifecycle = CapturePreviewLifecycleService(
            capturePreviewService: service,
            acquirePreview: { _, _ in
                switch await gate.nextOutcome() {
                case .success(let subscription):
                    return .started(subscription)
                case .failure(let error):
                    throw error
                }
            }
        )
        let display = CapturePreviewLifecycleMockSCDisplay.make(
            displayID: 719,
            width: 1920,
            height: 1080
        )
        let metadata = CapturePreviewDisplayMetadata(
            displayName: "Rebuild Display",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let firstTask = Task { @MainActor in
            try await lifecycle.startPreview(display: display, metadata: metadata)
        }
        #expect(await waitForAcquirePreviewCall(gate, count: 1))

        lifecycle.removePreviewSessions(displayID: 719)
        await gate.release(call: 1)

        let firstOutcome = try await firstTask.value
        if case .invalidated = firstOutcome {
        } else {
            Issue.record("Expected in-flight start to be invalidated by removePreviewSessions.")
        }

        #expect(service.currentSessions.isEmpty)
        #expect(await waitUntil { firstPreview.cancelCounter.value == 1 })

        let retryTask = Task { @MainActor in
            try await lifecycle.startPreview(display: display, metadata: metadata)
        }
        #expect(await waitForAcquirePreviewCall(gate, count: 2))
        await gate.release(call: 2)
        let retryOutcome = try await retryTask.value
        let retryID: UUID
        switch retryOutcome {
        case .started(let id):
            retryID = id
        case .invalidated:
            Issue.record("Expected retry preview start to succeed.")
            return
        }

        #expect(retryID == service.currentSessions.first?.id)
        #expect(service.currentSessions.count == 1)
        #expect(secondPreview.cancelCounter.value == 0)
    }

    @Test func removePreviewSessionsPreventsStaleSessionWriteWhenAcquireResumesAfterInvalidation() async throws {
        let service = CapturePreviewService()
        let preview = makePreview(displayID: 720)
        let gate = CapturePreviewLifecycleAcquirePreviewGate(
            scriptedOutcomes: [.success(preview.subscription)]
        )
        let lifecycle = CapturePreviewLifecycleService(
            capturePreviewService: service,
            acquirePreview: { _, _ in
                switch await gate.nextOutcome() {
                case .success(let subscription):
                    return .started(subscription)
                case .failure(let error):
                    throw error
                }
            }
        )
        let display = CapturePreviewLifecycleMockSCDisplay.make(
            displayID: 720,
            width: 1920,
            height: 1080
        )
        let metadata = CapturePreviewDisplayMetadata(
            displayName: "Cancelled Display",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let task = Task { @MainActor in
            try await lifecycle.startPreview(display: display, metadata: metadata)
        }
        #expect(await waitForAcquirePreviewCall(gate, count: 1))

        lifecycle.removePreviewSessions(displayID: 720)
        await gate.release(call: 1)

        let outcome = try await task.value
        if case .invalidated = outcome {
        } else {
            Issue.record("Expected invalidated outcome after removing preview sessions.")
        }

        #expect(service.currentSessions.isEmpty)
        #expect(await waitUntil { preview.cancelCounter.value == 1 })
    }

    @Test func unknownSessionIDsAreNoOpForActivateAttachAndClose() async throws {
        let service = MockCapturePreviewService()
        let record = makeSession(id: UUID(), displayID: 711)
        service.currentSessions = [record.session]
        let lifecycle = CapturePreviewLifecycleService(capturePreviewService: service)
        let sink = CapturePreviewLifecyclePreviewSink()

        lifecycle.activatePreviewSession(id: UUID())
        lifecycle.attachPreviewSink(sink, to: UUID())
        try await lifecycle.setPreviewSessionCapturesCursor(id: UUID(), capturesCursor: true)
        lifecycle.closePreviewSession(id: UUID())

        #expect(service.updateStateCallCount == 0)
        #expect(service.updateCapturesCursorCallCount == 0)
        #expect(service.removeCallCount == 0)
        #expect(record.captureSession.attachedSinkCount == 0)
        #expect(record.captureSession.cursorUpdateCount == 0)
        #expect(service.currentSessions.map(\.id) == [record.session.id])
    }

    private func makePreview(
        displayID: CGDirectDisplayID
    ) -> (
        subscription: DisplayPreviewSubscription,
        captureSession: CapturePreviewLifecycleDummySession,
        cancelCounter: CapturePreviewLifecycleCancelCounter
    ) {
        let captureSession = CapturePreviewLifecycleDummySession()
        let cancelCounter = CapturePreviewLifecycleCancelCounter()
        let subscription = DisplayPreviewSubscription(
            displayID: displayID,
            resolutionText: "1920 × 1080",
            session: captureSession,
            cancelClosure: { cancelCounter.value += 1 },
            setShowsCursorClosure: { showsCursor in
                try await captureSession.setDemand(
                    DisplayCaptureDemandSnapshot(
                        previewShowsCursor: showsCursor,
                        performanceMode: .automatic
                    )
                )
            }
        )
        return (subscription, captureSession, cancelCounter)
    }

    private func makeSession(
        id: UUID,
        displayID: CGDirectDisplayID
    ) -> (
        session: ScreenPreviewSession,
        captureSession: CapturePreviewLifecycleDummySession,
        cancelCounter: CapturePreviewLifecycleCancelCounter
    ) {
        let preview = makePreview(displayID: displayID)
        let session = ScreenPreviewSession(
            id: id,
            displayID: displayID,
            displayName: "Display \(displayID)",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false,
            previewSubscription: preview.subscription,
            capturesCursor: false,
            state: .starting
        )
        return (session, preview.captureSession, preview.cancelCounter)
    }

    private func waitForAcquirePreviewCall(
        _ gate: CapturePreviewLifecycleAcquirePreviewGate,
        count: Int
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + AsyncTestTimeouts.defaultAsyncAssertion
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await gate.currentCallCount() >= count {
                return true
            }
            await Task.yield()
        }
        return await gate.currentCallCount() >= count
    }
}
