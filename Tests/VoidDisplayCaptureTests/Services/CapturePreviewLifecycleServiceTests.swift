@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
import CoreGraphics
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

private final class CapturePreviewLifecycleCancelCounter: @unchecked Sendable {
    nonisolated(unsafe) var value = 0
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
    @Test func previewServicePreservesActiveStateAndCancelsOnlyRemovedSessions() async {
        let first = makeSession(id: UUID(), displayID: 720)
        let second = makeSession(id: UUID(), displayID: 721)
        let service = CapturePreviewService(initialSessions: [first.session, second.session])

        service.updatePreviewSessionState(id: first.session.id, state: .active)
        service.updatePreviewSessionState(id: first.session.id, state: .starting)
        service.updatePreviewSessionCapturesCursor(id: first.session.id, capturesCursor: true)
        #expect(service.previewSession(for: first.session.id)?.state == .active)
        #expect(service.previewSession(for: first.session.id)?.capturesCursor == true)

        service.removePreviewSessions(displayID: 720)
        #expect(service.currentSessions.map(\.id) == [second.session.id])
        #expect(await waitUntil { first.cancelCounter.value == 1 })
        #expect(second.cancelCounter.value == 0)

        service.removePreviewSession(id: second.session.id)
        #expect(service.currentSessions.isEmpty)
        #expect(await waitUntil { second.cancelCounter.value == 1 })
    }

    @Test func startPreviewCreatesSessionAndReturnsID() async throws {
        let service = MockCapturePreviewService()
        let previewRecord = makePreview(displayID: 701)
        let lifecycle = CapturePreviewLifecycleService(
            capturePreviewService: service,
            acquirePreview: { _, _ in .started(previewRecord.subscription) }
        )
        let display = SharedMockSCDisplay.make(
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
        let display = SharedMockSCDisplay.make(
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
        let display = SharedMockSCDisplay.make(
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
        let display = SharedMockSCDisplay.make(
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
        let display = SharedMockSCDisplay.make(
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
