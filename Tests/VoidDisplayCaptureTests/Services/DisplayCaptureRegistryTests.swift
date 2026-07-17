@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
import CoreGraphics
import ScreenCaptureKit
import Synchronization
import Testing

private final class FakeCaptureSession: DisplayCaptureSessioning, @unchecked Sendable {
    private struct Counters {
        var stopSharingCalls = 0
        var stopCalls = 0
        var setDemandCalls: [DisplayCaptureDemandSnapshot] = []
    }

    private let counters = Mutex(Counters())
    nonisolated let testShareFrameConsumer = TestDisplayShareFrameConsumer()
    nonisolated var shareFrameConsumer: any DisplayShareFrameConsumer { testShareFrameConsumer }

    nonisolated func attachPreviewSink(_ _: any DisplayPreviewSink) {}

    nonisolated func detachPreviewSink(_ _: any DisplayPreviewSink) {}

    nonisolated func stopSharing() {
        counters.withLock { $0.stopSharingCalls += 1 }
    }

    nonisolated func setDemand(_ demand: DisplayCaptureDemandSnapshot) async throws {
        shareFrameConsumer.updatePerformanceMode(demand.performanceMode)
        counters.withLock { $0.setDemandCalls.append(demand) }
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

    var setDemandCalls: [DisplayCaptureDemandSnapshot] {
        counters.withLock { $0.setDemandCalls }
    }
}

private actor SharingStateGate {
    private var isOpen = false
    private var enteredFalse = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForFalseEntry() async {
        guard !enteredFalse else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func waitUntilOpen() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func markFalseEntered() {
        guard !enteredFalse else { return }
        enteredFalse = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private final class BlockingSetSharingActiveSession: DisplayCaptureSessioning, @unchecked Sendable {
    private struct Counters {
        var stopSharingCalls = 0
        var stopCalls = 0
        var setDemandCalls: [DisplayCaptureDemandSnapshot] = []
    }

    nonisolated let shareFrameConsumer: any DisplayShareFrameConsumer = TestDisplayShareFrameConsumer()
    private let counters = Mutex(Counters())
    private let gate: SharingStateGate

    init(gate: SharingStateGate) {
        self.gate = gate
    }

    nonisolated func attachPreviewSink(_ _: any DisplayPreviewSink) {}

    nonisolated func detachPreviewSink(_ _: any DisplayPreviewSink) {}

    nonisolated func stopSharing() {
        counters.withLock { $0.stopSharingCalls += 1 }
    }

    nonisolated func setDemand(_ demand: DisplayCaptureDemandSnapshot) async throws {
        counters.withLock { $0.setDemandCalls.append(demand) }
        guard demand.shareTokenCount == 0 else { return }
        await gate.markFalseEntered()
        await gate.waitUntilOpen()
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

    var setDemandCalls: [DisplayCaptureDemandSnapshot] {
        counters.withLock { $0.setDemandCalls }
    }
}

private final class BlockingStopCaptureSession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let shareFrameConsumer: any DisplayShareFrameConsumer = TestDisplayShareFrameConsumer()
    private let gate: SharingStateGate
    private let stopCallCountValue = Mutex(0)

    init(gate: SharingStateGate) {
        self.gate = gate
    }

    nonisolated func attachPreviewSink(_ _: any DisplayPreviewSink) {}

    nonisolated func detachPreviewSink(_ _: any DisplayPreviewSink) {}

    nonisolated func stopSharing() {}

    nonisolated func setDemand(_ _: DisplayCaptureDemandSnapshot) async throws {}

    nonisolated func stop() async {
        stopCallCountValue.withLock { $0 += 1 }
        await gate.markFalseEntered()
        await gate.waitUntilOpen()
    }

    var stopCallCount: Int {
        stopCallCountValue.withLock { $0 }
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
        #expect(fakeSession.setDemandCalls.last?.shareTokenCount == 0)
        #expect(fakeSession.stopCalls == 0)
        #expect(await registry.sessionState(for: displayID) == .active)

        await registry.release(previewToken)
        let previewReleaseSettled = await waitUntil {
            let state = await registry.sessionState(for: displayID)
            return fakeSession.stopCalls == 1 && state == .stopped
        }
        #expect(previewReleaseSettled)
    }

    @Test func concurrentAcquirePreviewDoesNotLoseTokenOwnership() async throws {
        let displayID = CGDirectDisplayID(6060)
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let sendableDisplay = SendableDisplay(display)
        let gate = CaptureSessionFactoryGate()
        let fakeSession = FakeCaptureSession()
        let factoryCallCount = Mutex(0)

        let registry = DisplayCaptureRegistry(captureSessionFactory: { _, _, _, _ in
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

    @Test func concurrentPreviewAndShareCreationUsesMixedInitialProfile() async throws {
        let displayID = CGDirectDisplayID(9090)
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let sendableDisplay = SendableDisplay(display)
        let fakeSession = FakeCaptureSession()
        let factoryGate = CaptureSessionFactoryGate()
        let initialProfiles = Mutex<[DisplayCaptureProfile]>([])
        let registry = DisplayCaptureRegistry(captureSessionFactory: { _, initialProfile, _, _ in
            initialProfiles.withLock { $0.append(initialProfile) }
            await factoryGate.waitUntilOpen()
            return fakeSession
        })

        async let previewSubscription = registry.acquirePreview(display: sendableDisplay)
        async let shareSubscription = registry.acquireShare(display: sendableDisplay)

        await factoryGate.open()

        let preview = try await previewSubscription
        let share = try await shareSubscription

        #expect(initialProfiles.withLock { $0.first } == .mixed)

        preview.cancel()
        share.cancel()
        let drained = await waitUntil {
            await registry.sessionState(for: displayID) == .stopped
        }
        #expect(drained)
    }

    @Test func releaseWhileSetSharingActiveSuspendsDoesNotOverwriteConcurrentAcquire() async throws {
        let displayID = CGDirectDisplayID(10010)
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let sendableDisplay = SendableDisplay(display)
        let gate = SharingStateGate()
        let session = BlockingSetSharingActiveSession(gate: gate)
        let registry = DisplayCaptureRegistry()

        await registry.installSessionForTesting(
            displayID: displayID,
            resolutionText: "1920 × 1080",
            session: session
        )

        let previewToken = try await registry.acquirePreviewTokenForTesting(displayID: displayID)
        let firstToken = try await registry.acquireShareToken(display: sendableDisplay)
        let releaseTask = Task {
            await registry.release(firstToken)
        }

        await gate.waitForFalseEntry()

        let secondToken = try await registry.acquireShareToken(display: sendableDisplay)
        #expect(await registry.sessionState(for: displayID) == .active)

        await gate.open()
        await releaseTask.value

        #expect(await registry.sessionState(for: displayID) == .active)
        #expect(session.stopCalls == 0)
        #expect(session.stopSharingCalls == 1)

        await registry.release(secondToken)
        #expect(await registry.sessionState(for: displayID) == .active)

        await registry.release(previewToken)
        let drained = await waitUntil {
            await registry.sessionState(for: displayID) == .stopped
        }
        #expect(drained)
        #expect(session.stopCalls == 1)
    }

    @Test func acquireDuringLastTokenDrainWaitsForReplacementSession() async throws {
        let displayID = CGDirectDisplayID(10011)
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let sendableDisplay = SendableDisplay(display)
        let stopGate = SharingStateGate()
        let drainingSession = BlockingStopCaptureSession(gate: stopGate)
        let replacementSession = FakeCaptureSession()
        let factoryCallCount = Mutex(0)
        let registry = DisplayCaptureRegistry(captureSessionFactory: { _, _, _, _ in
            factoryCallCount.withLock { $0 += 1 }
            return replacementSession
        })

        await registry.installSessionForTesting(
            displayID: displayID,
            resolutionText: "1920 × 1080",
            session: drainingSession
        )
        let originalToken = try await registry.acquirePreviewTokenForTesting(displayID: displayID)

        await registry.release(originalToken)
        await stopGate.waitForFalseEntry()
        #expect(await registry.sessionState(for: displayID) == .draining)

        let replacementAcquire = Task {
            try await registry.acquirePreview(display: sendableDisplay)
        }
        #expect(
            await staysTrue(timeoutNanoseconds: 50_000_000) {
                factoryCallCount.withLock { $0 } == 0
            }
        )

        await stopGate.open()
        let replacementSubscription = try await replacementAcquire.value

        #expect(drainingSession.stopCallCount == 1)
        #expect(factoryCallCount.withLock { $0 } == 1)
        #expect(await registry.sessionState(for: displayID) == .active)

        replacementSubscription.cancel()
        let drained = await waitUntil {
            await registry.sessionState(for: displayID) == .stopped
        }
        #expect(drained)
        #expect(replacementSession.stopCalls == 1)
    }

    @Test func updatingPerformanceModePropagatesToExistingSessionsAndNewSessions() async throws {
        let displayID = CGDirectDisplayID(11011)
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let sendableDisplay = SendableDisplay(display)
        let installedSession = FakeCaptureSession()
        let createdSession = FakeCaptureSession()
        let createdModes = Mutex<[CapturePerformanceMode]>([])
        let registry = DisplayCaptureRegistry(
            performanceMode: .automatic,
            captureSessionFactory: { _, _, mode, _ in
                createdModes.withLock { $0.append(mode) }
                return createdSession
            }
        )

        await registry.installSessionForTesting(
            displayID: displayID,
            resolutionText: "1920 × 1080",
            session: installedSession
        )

        await registry.updatePerformanceMode(.powerEfficient)
        #expect(installedSession.setDemandCalls.last?.performanceMode == .powerEfficient)
        #expect(installedSession.testShareFrameConsumer.recordedPerformanceModes.last == .powerEfficient)

        let subscription = try await registry.acquireShare(display: sendableDisplay)

        #expect(createdModes.withLock { $0.first } == nil)
        #expect(installedSession.setDemandCalls.last?.shareTokenCount == 1)

        subscription.cancel()

        let newDisplayID = CGDirectDisplayID(11012)
        let newDisplay = SharedMockSCDisplay.make(displayID: newDisplayID, width: 1280, height: 720)
        let newSubscription = try await registry.acquireShare(display: SendableDisplay(newDisplay))
        #expect(createdModes.withLock { $0.first } == .powerEfficient)
        newSubscription.cancel()
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

private final class SessionStoreFakeSession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let shareFrameConsumer: any DisplayShareFrameConsumer = TestDisplayShareFrameConsumer()
    private let stopCallCountValue = Mutex(0)

    nonisolated func attachPreviewSink(_ _: any DisplayPreviewSink) {}

    nonisolated func detachPreviewSink(_ _: any DisplayPreviewSink) {}

    nonisolated func stopSharing() {}

    nonisolated func setDemand(_ _: DisplayCaptureDemandSnapshot) async throws {}

    nonisolated func stop() async {
        stopCallCountValue.withLock { $0 += 1 }
    }

    var stopCallCount: Int {
        stopCallCountValue.withLock { $0 }
    }
}

struct DisplayCaptureLeaseBookTests {
    @Test func initialProfileUsesPendingCreationDemand() {
        var book = DisplayCaptureLeaseBook()
        let displayID = CGDirectDisplayID(21001)

        book.recordPendingCreationDemand(for: displayID, kind: .preview, delta: 1)
        #expect(book.initialProfile(for: displayID, fallbackKind: .preview) == .previewOnly)

        book.recordPendingCreationDemand(for: displayID, kind: .share, delta: 1)
        #expect(book.initialProfile(for: displayID, fallbackKind: .preview) == .mixed)

        book.recordPendingCreationDemand(for: displayID, kind: .preview, delta: -1)
        #expect(book.initialProfile(for: displayID, fallbackKind: .preview) == .shareOnly)
    }

    @Test func demandSnapshotCombinesPreviewShareAndCursorState() {
        var book = DisplayCaptureLeaseBook()
        let displayID = CGDirectDisplayID(21002)

        let previewToken = book.registerToken(displayID: displayID, kind: .preview)
        let shareToken = book.registerToken(displayID: displayID, kind: .share)

        #expect(book.recordAttachedPreviewSinkDelta(2, for: previewToken) == displayID)
        let cursorMutation = book.setPreviewShowsCursor(true, for: previewToken)
        #expect(cursorMutation?.previousValue == false)
        #expect(book.prepareShareForSharing(shareToken) == displayID)

        let snapshot = book.demandSnapshot(for: displayID, performanceMode: .smooth)

        #expect(snapshot.attachedPreviewSinkCount == 2)
        #expect(snapshot.shareTokenCount == 1)
        #expect(snapshot.previewShowsCursor)
        #expect(snapshot.shareCursorOverrideCount == 1)
        #expect(snapshot.performanceMode == .smooth)
        #expect(snapshot.showsCursor)
        #expect(snapshot.desiredProfile == .mixed)
    }

    @Test func preparedShareRollbackAndCancelClearCursorOverrideDemand() {
        var book = DisplayCaptureLeaseBook()
        let displayID = CGDirectDisplayID(21003)
        let shareToken = book.registerToken(displayID: displayID, kind: .share)

        #expect(book.prepareShareForSharing(shareToken) == displayID)
        #expect(
            book.demandSnapshot(for: displayID, performanceMode: .automatic).shareCursorOverrideCount == 1
        )

        book.revertPreparedShare(shareToken)
        #expect(
            book.demandSnapshot(for: displayID, performanceMode: .automatic).shareCursorOverrideCount == 0
        )

        #expect(book.prepareShareForSharing(shareToken) == displayID)
        #expect(book.releasePreparedShare(shareToken) == displayID)
        #expect(
            book.demandSnapshot(for: displayID, performanceMode: .automatic).shareCursorOverrideCount == 0
        )
    }

    @Test func releasingShareTokenWithPreviewRemainingStopsSharingWithoutDraining() {
        var book = DisplayCaptureLeaseBook()
        let displayID = CGDirectDisplayID(21004)
        _ = book.registerToken(displayID: displayID, kind: .preview)
        let shareToken = book.registerToken(displayID: displayID, kind: .share)

        let result = book.releaseToken(shareToken, expectedKind: .share)

        #expect(result?.displayID == displayID)
        #expect(result?.shouldStopSharing == true)
        #expect(result?.shouldApplyDemand == true)
        #expect(result?.shouldDrainSession == false)
    }

    @Test func releasingLastTokenRequestsDrain() {
        var book = DisplayCaptureLeaseBook()
        let displayID = CGDirectDisplayID(21005)
        let previewToken = book.registerToken(displayID: displayID, kind: .preview)

        let result = book.releaseToken(previewToken, expectedKind: .preview)

        #expect(result?.displayID == displayID)
        #expect(result?.shouldStopSharing == false)
        #expect(result?.shouldApplyDemand == false)
        #expect(result?.shouldDrainSession == true)
        #expect(book.hasActiveTokens(for: displayID) == false)
    }
}

struct DisplayCaptureSessionStoreTests {
    @Test func installedSessionIsImmediatelyActive() {
        var store = DisplayCaptureSessionStore()
        let displayID = CGDirectDisplayID(22001)
        let existingSession = SessionStoreFakeSession()

        store.installSessionForTesting(
            displayID: displayID,
            resolutionText: "1920 × 1080",
            session: existingSession
        )

        #expect(
            ObjectIdentifier(store.record(for: displayID)?.session as AnyObject)
                == ObjectIdentifier(existingSession)
        )
        #expect(store.sessionState(for: displayID) == .active)
    }

    @Test func initializingStateCanBeCancelled() {
        var store = DisplayCaptureSessionStore()
        let displayID = CGDirectDisplayID(22002)

        store.markInitializing(displayID: displayID)
        #expect(store.sessionState(for: displayID) == .initializing)
        store.cancelInitializing(displayID: displayID)
        #expect(store.sessionState(for: displayID) == .stopped)
    }

    @Test func finishDrainingRemovesSessionWhenNoTokensRemain() {
        var store = DisplayCaptureSessionStore()
        let displayID = CGDirectDisplayID(22003)
        let session = SessionStoreFakeSession()

        store.installSessionForTesting(
            displayID: displayID,
            resolutionText: "1280 × 720",
            session: session
        )
        store.beginDraining(displayID: displayID) { _ in }
        store.finishDraining(displayID: displayID, hasActiveTokens: false)

        #expect(store.record(for: displayID) == nil)
        #expect(store.sessionState(for: displayID) == .stopped)
    }

    @Test func finishDrainingRestoresActiveStateWhenTokensReappear() {
        var store = DisplayCaptureSessionStore()
        let displayID = CGDirectDisplayID(22004)
        let session = SessionStoreFakeSession()

        store.installSessionForTesting(
            displayID: displayID,
            resolutionText: "1600 × 900",
            session: session
        )
        store.beginDraining(displayID: displayID) { _ in }
        store.finishDraining(displayID: displayID, hasActiveTokens: true)

        #expect(store.record(for: displayID) != nil)
        #expect(store.sessionState(for: displayID) == .active)
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
