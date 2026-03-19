import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import Testing
@testable import VoidDisplay

private final class CaptureMonitoringLifecycleDummySession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let sessionHub = WebRTCSessionHub()

    nonisolated(unsafe) var attachedSinkCount = 0
    nonisolated(unsafe) var detachedSinkCount = 0
    nonisolated(unsafe) var cursorUpdateCount = 0
    nonisolated(unsafe) var lastShowsCursor: Bool?
    nonisolated(unsafe) var cursorUpdateError: Error?

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
        attachedSinkCount += 1
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
        detachedSinkCount += 1
    }

    nonisolated func stopSharing() {}

    nonisolated func setPreviewShowsCursor(_ showsCursor: Bool) async throws {
        cursorUpdateCount += 1
        lastShowsCursor = showsCursor
        if let cursorUpdateError {
            throw cursorUpdateError
        }
    }

    nonisolated func retainShareCursorOverride() async throws {}

    nonisolated func releaseShareCursorOverride() async throws {}

    nonisolated func stop() async {}
}

private final class CaptureMonitoringLifecyclePreviewSink: DisplayPreviewSink, @unchecked Sendable {
    nonisolated func submitFrame(_ sampleBuffer: CMSampleBuffer) {
        _ = sampleBuffer
    }
}

private final class CaptureMonitoringLifecycleCancelCounter: @unchecked Sendable {
    nonisolated(unsafe) var value = 0
}

private final class CaptureMonitoringLifecycleMockSCDisplayBox: NSObject {
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

private enum CaptureMonitoringLifecycleMockSCDisplay {
    static func make(displayID: CGDirectDisplayID, width: Int, height: Int) -> SCDisplay {
        let box = CaptureMonitoringLifecycleMockSCDisplayBox(
            displayID: displayID,
            width: width,
            height: height
        )
        return unsafeBitCast(box, to: SCDisplay.self)
    }
}

private struct CaptureMonitoringLifecycleControlledError: Error, Equatable {}

private actor CaptureMonitoringLifecycleAcquirePreviewGate {
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
struct CaptureMonitoringLifecycleServiceTests {
    @Test func startMonitoringCreatesSessionAndReturnsID() async throws {
        let service = MockCaptureMonitoringService()
        let previewRecord = makePreview(displayID: 701)
        let lifecycle = CaptureMonitoringLifecycleService(
            captureMonitoringService: service,
            acquirePreview: { _ in previewRecord.subscription }
        )
        let display = CaptureMonitoringLifecycleMockSCDisplay.make(
            displayID: 701,
            width: 1920,
            height: 1080
        )
        let metadata = CaptureMonitoringDisplayMetadata(
            displayName: "Studio Display",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let sessionID = try await lifecycle.startMonitoring(display: display, metadata: metadata)

        #expect(service.addCallCount == 1)
        #expect(service.currentSessions.count == 1)
        #expect(service.currentSessions.first?.id == sessionID)
        #expect(service.currentSessions.first?.displayName == "Studio Display")
        #expect(service.currentSessions.first?.resolutionText == "1920 × 1080")
        #expect(service.currentSessions.first?.isVirtualDisplay == false)
    }

    @Test func startMonitoringReusesExistingSessionIDForSameDisplay() async throws {
        let service = MockCaptureMonitoringService()
        let existing = makeSession(id: UUID(), displayID: 702)
        service.currentSessions = [existing.session]
        var acquirePreviewCallCount = 0
        let lifecycle = CaptureMonitoringLifecycleService(
            captureMonitoringService: service,
            acquirePreview: { _ in
                acquirePreviewCallCount += 1
                return makePreview(displayID: 702).subscription
            }
        )
        let display = CaptureMonitoringLifecycleMockSCDisplay.make(
            displayID: 702,
            width: 1920,
            height: 1080
        )

        let sessionID = try await lifecycle.startMonitoring(
            display: display,
            metadata: .init(
                displayName: "Ignored",
                resolutionText: "1920 × 1080",
                isVirtualDisplay: false
            )
        )

        #expect(sessionID == existing.session.id)
        #expect(acquirePreviewCallCount == 0)
        #expect(service.addCallCount == 0)
        #expect(service.currentSessions.count == 1)
    }

    @Test func startMonitoringUsesInjectedAcquirePreview() async throws {
        let service = MockCaptureMonitoringService()
        var usedInjectedAcquirePreview = false
        let lifecycle = CaptureMonitoringLifecycleService(
            captureMonitoringService: service,
            acquirePreview: { _ in
                usedInjectedAcquirePreview = true
                return makePreview(displayID: 703).subscription
            }
        )
        let display = CaptureMonitoringLifecycleMockSCDisplay.make(
            displayID: 703,
            width: 2560,
            height: 1440
        )

        _ = try await lifecycle.startMonitoring(
            display: display,
            metadata: .init(
                displayName: "Preview Source",
                resolutionText: "2560 × 1440",
                isVirtualDisplay: true
            )
        )

        #expect(usedInjectedAcquirePreview)
    }

    @Test func concurrentStartMonitoringForSameDisplayCreatesOneSessionAndOnePreviewAcquire() async throws {
        let service = MockCaptureMonitoringService()
        let preview = makePreview(displayID: 712)
        let gate = CaptureMonitoringLifecycleAcquirePreviewGate(
            scriptedOutcomes: [.success(preview.subscription)]
        )
        let lifecycle = CaptureMonitoringLifecycleService(
            captureMonitoringService: service,
            acquirePreview: { _ in
                switch await gate.nextOutcome() {
                case .success(let subscription):
                    return subscription
                case .failure(let error):
                    throw error
                }
            }
        )
        let display = CaptureMonitoringLifecycleMockSCDisplay.make(
            displayID: 712,
            width: 1920,
            height: 1080
        )
        let metadata = CaptureMonitoringDisplayMetadata(
            displayName: "Shared Display",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let firstTask = Task { @MainActor in
            try await lifecycle.startMonitoring(display: display, metadata: metadata)
        }
        #expect(await waitForAcquirePreviewCall(gate, count: 1))

        let secondTask = Task { @MainActor in
            try await lifecycle.startMonitoring(display: display, metadata: metadata)
        }
        let stayedSingleAcquire = await staysTrue {
            await gate.currentCallCount() == 1
        }
        #expect(stayedSingleAcquire)

        await gate.release(call: 1)
        let firstID = try await firstTask.value
        let secondID = try await secondTask.value

        #expect(firstID == secondID)
        #expect(service.addCallCount == 1)
        #expect(service.currentSessions.count == 1)
        #expect(service.currentSessions.first?.displayID == 712)
    }

    @Test func attachPreviewSinkTargetsRequestedSessionOnly() {
        let service = MockCaptureMonitoringService()
        let first = makeSession(id: UUID(), displayID: 704)
        let second = makeSession(id: UUID(), displayID: 705)
        service.currentSessions = [first.session, second.session]
        let lifecycle = CaptureMonitoringLifecycleService(captureMonitoringService: service)
        let sink = CaptureMonitoringLifecyclePreviewSink()

        lifecycle.attachPreviewSink(sink, to: second.session.id)

        #expect(first.captureSession.attachedSinkCount == 0)
        #expect(second.captureSession.attachedSinkCount == 1)
    }

    @Test func activateMonitoringSessionPromotesOnlyRequestedSession() {
        let service = MockCaptureMonitoringService()
        let first = makeSession(id: UUID(), displayID: 706)
        let second = makeSession(id: UUID(), displayID: 707)
        service.currentSessions = [first.session, second.session]
        let lifecycle = CaptureMonitoringLifecycleService(captureMonitoringService: service)

        lifecycle.activateMonitoringSession(id: second.session.id)

        #expect(service.currentSessions.first(where: { $0.id == first.session.id })?.state == .starting)
        #expect(service.currentSessions.first(where: { $0.id == second.session.id })?.state == .active)
        #expect(service.updateStateCallCount == 1)
    }

    @Test func setMonitoringSessionCapturesCursorWritesBackOnlyAfterPreviewUpdateSucceeds() async throws {
        let service = MockCaptureMonitoringService()
        let record = makeSession(id: UUID(), displayID: 708)
        service.currentSessions = [record.session]
        let lifecycle = CaptureMonitoringLifecycleService(captureMonitoringService: service)

        try await lifecycle.setMonitoringSessionCapturesCursor(
            id: record.session.id,
            capturesCursor: true
        )

        #expect(record.captureSession.cursorUpdateCount == 1)
        #expect(record.captureSession.lastShowsCursor == true)
        #expect(service.updateCapturesCursorCallCount == 1)
        #expect(service.currentSessions.first?.capturesCursor == true)
    }

    @Test func setMonitoringSessionCapturesCursorDoesNotWriteBackWhenPreviewUpdateFails() async {
        let service = MockCaptureMonitoringService()
        let record = makeSession(id: UUID(), displayID: 709)
        record.captureSession.cursorUpdateError = CaptureMonitoringLifecycleControlledError()
        service.currentSessions = [record.session]
        let lifecycle = CaptureMonitoringLifecycleService(captureMonitoringService: service)

        do {
            try await lifecycle.setMonitoringSessionCapturesCursor(
                id: record.session.id,
                capturesCursor: true
            )
            Issue.record("Expected cursor update failure.")
        } catch is CaptureMonitoringLifecycleControlledError {
        } catch {
            Issue.record("Expected CaptureMonitoringLifecycleControlledError, got \(error)")
        }

        #expect(record.captureSession.cursorUpdateCount == 1)
        #expect(service.updateCapturesCursorCallCount == 0)
        #expect(service.currentSessions.first?.capturesCursor == false)
    }

    @Test func closeMonitoringSessionUsesRemovePathOnly() {
        let service = MockCaptureMonitoringService()
        let record = makeSession(id: UUID(), displayID: 710)
        service.currentSessions = [record.session]
        let lifecycle = CaptureMonitoringLifecycleService(captureMonitoringService: service)

        lifecycle.closeMonitoringSession(id: record.session.id)

        #expect(service.removeCallCount == 1)
        #expect(record.cancelCounter.value == 0)
        #expect(service.currentSessions.isEmpty)
    }

    @Test func failedInFlightStartClearsMutualExclusionAndAllowsRetry() async {
        let service = MockCaptureMonitoringService()
        let secondPreview = makePreview(displayID: 713)
        let gate = CaptureMonitoringLifecycleAcquirePreviewGate(
            scriptedOutcomes: [
                .failure(CaptureMonitoringLifecycleControlledError()),
                .success(secondPreview.subscription)
            ]
        )
        let lifecycle = CaptureMonitoringLifecycleService(
            captureMonitoringService: service,
            acquirePreview: { _ in
                switch await gate.nextOutcome() {
                case .success(let subscription):
                    return subscription
                case .failure(let error):
                    throw error
                }
            }
        )
        let display = CaptureMonitoringLifecycleMockSCDisplay.make(
            displayID: 713,
            width: 1920,
            height: 1080
        )
        let metadata = CaptureMonitoringDisplayMetadata(
            displayName: "Retry Display",
            resolutionText: "1920 × 1080",
            isVirtualDisplay: false
        )

        let firstTask = Task { @MainActor in
            try await lifecycle.startMonitoring(display: display, metadata: metadata)
        }
        #expect(await waitForAcquirePreviewCall(gate, count: 1))
        await gate.release(call: 1)

        do {
            _ = try await firstTask.value
            Issue.record("Expected first start to fail.")
        } catch is CaptureMonitoringLifecycleControlledError {
        } catch {
            Issue.record("Expected CaptureMonitoringLifecycleControlledError, got \(error)")
        }

        let retryTask = Task { @MainActor in
            try await lifecycle.startMonitoring(display: display, metadata: metadata)
        }
        #expect(await waitForAcquirePreviewCall(gate, count: 2))
        await gate.release(call: 2)
        let retryID = try? await retryTask.value

        #expect(retryID != nil)
        #expect(service.addCallCount == 1)
        #expect(service.currentSessions.count == 1)
        #expect(service.currentSessions.first?.displayID == 713)
    }

    @Test func unknownSessionIDsAreNoOpForActivateAttachAndClose() async throws {
        let service = MockCaptureMonitoringService()
        let record = makeSession(id: UUID(), displayID: 711)
        service.currentSessions = [record.session]
        let lifecycle = CaptureMonitoringLifecycleService(captureMonitoringService: service)
        let sink = CaptureMonitoringLifecyclePreviewSink()

        lifecycle.activateMonitoringSession(id: UUID())
        lifecycle.attachPreviewSink(sink, to: UUID())
        try await lifecycle.setMonitoringSessionCapturesCursor(id: UUID(), capturesCursor: true)
        lifecycle.closeMonitoringSession(id: UUID())

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
        captureSession: CaptureMonitoringLifecycleDummySession,
        cancelCounter: CaptureMonitoringLifecycleCancelCounter
    ) {
        let captureSession = CaptureMonitoringLifecycleDummySession()
        let cancelCounter = CaptureMonitoringLifecycleCancelCounter()
        let subscription = DisplayPreviewSubscription(
            displayID: displayID,
            resolutionText: "1920 × 1080",
            session: captureSession,
            cancelClosure: { cancelCounter.value += 1 }
        )
        return (subscription, captureSession, cancelCounter)
    }

    private func makeSession(
        id: UUID,
        displayID: CGDirectDisplayID
    ) -> (
        session: ScreenMonitoringSession,
        captureSession: CaptureMonitoringLifecycleDummySession,
        cancelCounter: CaptureMonitoringLifecycleCancelCounter
    ) {
        let preview = makePreview(displayID: displayID)
        let session = ScreenMonitoringSession(
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
        _ gate: CaptureMonitoringLifecycleAcquirePreviewGate,
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
