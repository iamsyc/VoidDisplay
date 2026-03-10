import CoreGraphics
import ScreenCaptureKit
import Synchronization
import Testing
@testable import VoidDisplay

private final class FakeCaptureSession: DisplayCaptureSessioning, @unchecked Sendable {
    private struct Counters {
        var stopSharingCalls = 0
        var stopCalls = 0
    }

    private let counters = Mutex(Counters())
    nonisolated let sessionHub = WebRTCSessionHub()

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func stopSharing() {
        counters.withLock { $0.stopSharingCalls += 1 }
    }

    nonisolated func stop() async {
        counters.withLock { $0.stopCalls += 1 }
    }

    var stopSharingCalls: Int {
        counters.withLock { $0.stopSharingCalls }
    }

    var stopCalls: Int {
        counters.withLock { $0.stopCalls }
    }
}

private actor SessionStopGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilOpen() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private final class ControlledStopCaptureSession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let sessionHub = WebRTCSessionHub()
    private let stopGate: SessionStopGate
    private let counters = Mutex((stopSharing: 0, stop: 0))

    init(stopGate: SessionStopGate) {
        self.stopGate = stopGate
    }

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func stopSharing() {
        counters.withLock { $0.stopSharing += 1 }
    }

    nonisolated func stop() async {
        counters.withLock { $0.stop += 1 }
        await stopGate.waitUntilOpen()
    }
}

struct DisplayCaptureRegistryTests {
    @Test func releasingShareKeepsPreviewSessionAliveUntilLastToken() async throws {
        let registry = DisplayCaptureRegistry()
        let fakeSession = FakeCaptureSession()
        let displayID = CGDirectDisplayID(4040)
        await registry.installSessionForTesting(
            displayID: displayID,
            resolutionText: "3840 × 2160",
            session: fakeSession
        )

        let previewToken = try await registry.acquirePreviewTokenForTesting(displayID: displayID)
        let shareToken = try await registry.acquireShareTokenForTesting(displayID: displayID)

        await registry.release(shareToken)
        #expect(fakeSession.stopSharingCalls == 1)
        #expect(fakeSession.stopCalls == 0)
        #expect(await registry.sessionState(for: displayID) == .active)

        await registry.release(previewToken)
        let previewReleaseSettled = await waitUntil {
            let state = await registry.sessionState(for: displayID)
            return fakeSession.stopCalls == 1 && state == .stopped
        }
        #expect(previewReleaseSettled)
    }

    @Test func releasingSameTokenTwiceIsIdempotent() async throws {
        let registry = DisplayCaptureRegistry()
        let fakeSession = FakeCaptureSession()
        let displayID = CGDirectDisplayID(5050)
        await registry.installSessionForTesting(
            displayID: displayID,
            resolutionText: "2560 × 1440",
            session: fakeSession
        )

        let previewToken = try await registry.acquirePreviewTokenForTesting(displayID: displayID)
        await registry.release(previewToken)
        await registry.release(previewToken)

        let releaseSettled = await waitUntil {
            let state = await registry.sessionState(for: displayID)
            return fakeSession.stopCalls == 1 && state == .stopped
        }
        #expect(releaseSettled)
    }

    @Test func concurrentAcquirePreviewDoesNotLoseTokenOwnership() async throws {
        let displayID = CGDirectDisplayID(6060)
        let display = MockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let sendableDisplay = SendableDisplay(display)
        let gate = CaptureSessionFactoryGate()
        let fakeSession = FakeCaptureSession()
        let factoryCallCount = Mutex(0)

        let registry = DisplayCaptureRegistry(captureSessionFactory: { _ in
            factoryCallCount.withLock { $0 += 1 }
            await gate.waitUntilOpen()
            return fakeSession
        })

        async let firstAcquire = registry.acquirePreview(display: sendableDisplay)
        async let secondAcquire = registry.acquirePreview(display: sendableDisplay)

        await gate.open()

        let firstSubscription = try await firstAcquire
        let secondSubscription = try await secondAcquire

        #expect(factoryCallCount.withLock { $0 } == 1)
        #expect(await registry.sessionState(for: displayID) == .active)

        firstSubscription.cancel()
        let firstReleaseSettled = await waitUntil {
            let state = await registry.sessionState(for: displayID)
            return fakeSession.stopCalls == 0 && state == .active
        }
        #expect(firstReleaseSettled)

        secondSubscription.cancel()
        let secondReleaseSettled = await waitUntil {
            let state = await registry.sessionState(for: displayID)
            return fakeSession.stopCalls == 1 && state == .stopped
        }
        #expect(secondReleaseSettled)
    }

    @Test func acquireWaitsForDrainingSessionToStopBeforeRecreating() async throws {
        let displayID = CGDirectDisplayID(7070)
        let display = MockSCDisplay.make(displayID: displayID, width: 2560, height: 1440)
        let sendableDisplay = SendableDisplay(display)
        let stopGate = SessionStopGate()
        let initialSession = ControlledStopCaptureSession(stopGate: stopGate)
        let replacementSession = FakeCaptureSession()
        let factoryCallCount = Mutex(0)

        let registry = DisplayCaptureRegistry(captureSessionFactory: { _ in
            factoryCallCount.withLock { $0 += 1 }
            return replacementSession
        })
        await registry.installSessionForTesting(
            displayID: displayID,
            resolutionText: "2560 × 1440",
            session: initialSession
        )

        let previewToken = try await registry.acquirePreviewTokenForTesting(displayID: displayID)
        let releaseTask = Task {
            await registry.release(previewToken)
        }

        let drainingObserved = await waitUntil {
            await registry.sessionState(for: displayID) == .draining
        }
        #expect(drainingObserved)

        let acquireTask = Task {
            try await registry.acquirePreview(display: sendableDisplay)
        }

        #expect(
            await staysTrue(timeoutNanoseconds: 50_000_000) {
                factoryCallCount.withLock { $0 } == 0
            }
        )

        await stopGate.open()
        await releaseTask.value

        let replacementSubscription = try await acquireTask.value
        #expect(factoryCallCount.withLock { $0 } == 1)
        replacementSubscription.cancel()

        let drained = await waitUntil {
            await registry.sessionState(for: displayID) == .stopped
        }
        #expect(drained)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return await condition()
    }
}

private actor CaptureSessionFactoryGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilOpen() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}

private final class MockSCDisplayBox: NSObject {
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

private enum MockSCDisplay {
    static func make(displayID: CGDirectDisplayID, width: Int, height: Int) -> SCDisplay {
        let box = MockSCDisplayBox(displayID: displayID, width: width, height: height)
        return unsafeBitCast(box, to: SCDisplay.self)
    }
}
