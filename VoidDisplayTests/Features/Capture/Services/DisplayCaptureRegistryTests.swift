import CoreGraphics
import ScreenCaptureKit
import Synchronization
import Testing
@testable import VoidDisplay

private final class FakeCaptureSession: DisplayCaptureSessioning, @unchecked Sendable {
    private struct Counters {
        var stopSharingCalls = 0
        var stopCalls = 0
        var setDemandCalls: [DisplayCaptureDemandSnapshot] = []
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

    nonisolated func setDemand(_ demand: DisplayCaptureDemandSnapshot) async throws {
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

    nonisolated func setDemand(_ demand: DisplayCaptureDemandSnapshot) async throws {
        _ = demand
    }

    nonisolated func stop() async {
        counters.withLock { $0.stop += 1 }
        await stopGate.waitUntilOpen()
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

    nonisolated let sessionHub = WebRTCSessionHub()
    private let counters = Mutex(Counters())
    private let gate: SharingStateGate

    init(gate: SharingStateGate) {
        self.gate = gate
    }

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

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

private enum CursorOverrideTrackingError: Error {
    case forcedRetainFailure
}

private final class CursorOverrideTrackingSession: @unchecked Sendable {
    private struct State {
        var retainCalls = 0
        var releaseCalls = 0
        var pendingRetainFailures: [Bool]
    }

    private let state: Mutex<State>

    init(retainFailures: [Bool] = []) {
        self.state = Mutex(State(pendingRetainFailures: retainFailures))
    }

    nonisolated let sessionHub = WebRTCSessionHub()

    nonisolated func prepareForSharing() async throws {
        let shouldFail = state.withLock { state -> Bool in
            state.retainCalls += 1
            guard !state.pendingRetainFailures.isEmpty else {
                return false
            }
            return state.pendingRetainFailures.removeFirst()
        }
        if shouldFail {
            throw CursorOverrideTrackingError.forcedRetainFailure
        }
    }

    nonisolated func releasePreparedShare() async {
        state.withLock { $0.releaseCalls += 1 }
    }

    var retainCalls: Int {
        state.withLock { $0.retainCalls }
    }

    var releaseCalls: Int {
        state.withLock { $0.releaseCalls }
    }
}

struct DisplayCaptureRegistryTests {
    @Test func shareSubscriptionDoesNotReleaseCursorOverrideWhenRetainFails() async throws {
        let session = CursorOverrideTrackingSession(retainFailures: [true])
        let cancelCount = Mutex(0)
        let subscription = DisplayShareSubscription(
            displayID: CGDirectDisplayID(12001),
            sessionHub: session.sessionHub,
            cancelClosure: {
                cancelCount.withLock { $0 += 1 }
            },
            prepareForSharingClosure: {
                try await session.prepareForSharing()
            },
            releasePreparedShareClosure: {
                await session.releasePreparedShare()
            }
        )
        let invalidationContext = DisplayStartInvalidationContext()

        do {
            _ = try await subscription.prepareForSharing(invalidationContext: invalidationContext)
            Issue.record("Expected prepareForSharing to fail.")
        } catch {
        }

        let settled = await waitUntil {
            cancelCount.withLock { $0 } == 1 &&
                session.retainCalls == 1 &&
                session.releaseCalls == 0
        }
        #expect(settled)
    }

    @Test func shareSubscriptionReleasesCursorOverrideAfterSuccessfulRetain() async throws {
        let session = CursorOverrideTrackingSession()
        let cancelCount = Mutex(0)
        let subscription = DisplayShareSubscription(
            displayID: CGDirectDisplayID(12002),
            sessionHub: session.sessionHub,
            cancelClosure: {
                cancelCount.withLock { $0 += 1 }
            },
            prepareForSharingClosure: {
                try await session.prepareForSharing()
            },
            releasePreparedShareClosure: {
                await session.releasePreparedShare()
            }
        )
        let invalidationContext = DisplayStartInvalidationContext()

        let outcome = try await subscription.prepareForSharing(invalidationContext: invalidationContext)
        if case .invalidated = outcome {
            Issue.record("Expected prepareForSharing to succeed.")
        }
        subscription.cancel()

        let settled = await waitUntil {
            cancelCount.withLock { $0 } == 1 &&
                session.retainCalls == 1 &&
                session.releaseCalls == 1
        }
        #expect(settled)
    }

    @Test func failedShareSubscriptionDoesNotReleaseCursorOverrideHeldByAnotherSubscription() async throws {
        let session = CursorOverrideTrackingSession(retainFailures: [false, true])
        let firstCancelCount = Mutex(0)
        let secondCancelCount = Mutex(0)
        let firstSubscription = DisplayShareSubscription(
            displayID: CGDirectDisplayID(12003),
            sessionHub: session.sessionHub,
            cancelClosure: {
                firstCancelCount.withLock { $0 += 1 }
            },
            prepareForSharingClosure: {
                try await session.prepareForSharing()
            },
            releasePreparedShareClosure: {
                await session.releasePreparedShare()
            }
        )
        let secondSubscription = DisplayShareSubscription(
            displayID: CGDirectDisplayID(12003),
            sessionHub: session.sessionHub,
            cancelClosure: {
                secondCancelCount.withLock { $0 += 1 }
            },
            prepareForSharingClosure: {
                try await session.prepareForSharing()
            },
            releasePreparedShareClosure: {
                await session.releasePreparedShare()
            }
        )

        let firstOutcome = try await firstSubscription.prepareForSharing(
            invalidationContext: DisplayStartInvalidationContext()
        )
        if case .invalidated = firstOutcome {
            Issue.record("Expected first retain to succeed.")
        }

        do {
            _ = try await secondSubscription.prepareForSharing(
                invalidationContext: DisplayStartInvalidationContext()
            )
            Issue.record("Expected second retain to fail.")
        } catch {
        }

        let secondFailureSettled = await waitUntil {
            firstCancelCount.withLock { $0 } == 0 &&
                secondCancelCount.withLock { $0 } == 1 &&
                session.retainCalls == 2 &&
                session.releaseCalls == 0
        }
        #expect(secondFailureSettled)

        firstSubscription.cancel()

        let firstCancelSettled = await waitUntil {
            firstCancelCount.withLock { $0 } == 1 &&
                session.releaseCalls == 1
        }
        #expect(firstCancelSettled)
    }

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

        let registry = DisplayCaptureRegistry(captureSessionFactory: { _, _, _ in
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

        let registry = DisplayCaptureRegistry(captureSessionFactory: { _, _, _ in
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

    @Test func acquiringShareFirstUsesShareOnlyInitialProfile() async throws {
        let displayID = CGDirectDisplayID(8080)
        let display = MockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let sendableDisplay = SendableDisplay(display)
        let fakeSession = FakeCaptureSession()
        let initialProfiles = Mutex<[DisplayCaptureProfile]>([])
        let registry = DisplayCaptureRegistry(captureSessionFactory: { _, initialProfile, _ in
            initialProfiles.withLock { $0.append(initialProfile) }
            return fakeSession
        })

        let subscription = try await registry.acquireShare(display: sendableDisplay)

        #expect(initialProfiles.withLock { $0.first } == .shareOnly)
        subscription.cancel()
        let drained = await waitUntil {
            await registry.sessionState(for: displayID) == .stopped
        }
        #expect(drained)
    }

    @Test func concurrentPreviewAndShareCreationUsesMixedInitialProfile() async throws {
        let displayID = CGDirectDisplayID(9090)
        let display = MockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let sendableDisplay = SendableDisplay(display)
        let fakeSession = FakeCaptureSession()
        let factoryGate = CaptureSessionFactoryGate()
        let initialProfiles = Mutex<[DisplayCaptureProfile]>([])
        let registry = DisplayCaptureRegistry(captureSessionFactory: { _, initialProfile, _ in
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
        let display = MockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
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

    @Test func updatingPerformanceModePropagatesToExistingSessionsAndNewSessions() async throws {
        let displayID = CGDirectDisplayID(11011)
        let display = MockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let sendableDisplay = SendableDisplay(display)
        let installedSession = FakeCaptureSession()
        let createdSession = FakeCaptureSession()
        let createdModes = Mutex<[CapturePerformanceMode]>([])
        let registry = DisplayCaptureRegistry(
            performanceMode: .automatic,
            captureSessionFactory: { _, _, mode in
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

        let subscription = try await registry.acquireShare(display: sendableDisplay)

        #expect(createdModes.withLock { $0.first } == nil)
        #expect(installedSession.setDemandCalls.last?.shareTokenCount == 1)

        subscription.cancel()

        let newDisplayID = CGDirectDisplayID(11012)
        let newDisplay = MockSCDisplay.make(displayID: newDisplayID, width: 1280, height: 720)
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

private actor SessionStoreStopGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilOpen() async {
        guard isOpen == false else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard isOpen == false else { return }
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}

private actor SessionStoreDrainFinisher {
    private let store: DisplayCaptureSessionStore

    init(store: DisplayCaptureSessionStore) {
        self.store = store
    }

    func finish(displayID: CGDirectDisplayID, hasActiveTokens: Bool) {
        store.finishDraining(displayID: displayID, hasActiveTokens: hasActiveTokens)
    }
}

private final class SessionStoreFakeSession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let sessionHub = WebRTCSessionHub()
    private let stopCallCountValue = Mutex(0)

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func stopSharing() {}

    nonisolated func setDemand(_ demand: DisplayCaptureDemandSnapshot) async throws {
        _ = demand
    }

    nonisolated func stop() async {
        stopCallCountValue.withLock { $0 += 1 }
    }

    var stopCallCount: Int {
        stopCallCountValue.withLock { $0 }
    }
}

private final class SessionStoreControlledStopSession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let sessionHub = WebRTCSessionHub()
    private let stopGate: SessionStoreStopGate
    private let stopCallCountValue = Mutex(0)

    init(stopGate: SessionStoreStopGate) {
        self.stopGate = stopGate
    }

    nonisolated func attachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func detachPreviewSink(_ sink: any DisplayPreviewSink) {
        _ = sink
    }

    nonisolated func stopSharing() {}

    nonisolated func setDemand(_ demand: DisplayCaptureDemandSnapshot) async throws {
        _ = demand
    }

    nonisolated func stop() async {
        stopCallCountValue.withLock { $0 += 1 }
        await stopGate.waitUntilOpen()
    }

    var stopCallCount: Int {
        stopCallCountValue.withLock { $0 }
    }
}

struct DisplayCaptureLeaseBookTests {
    @Test func initialProfileUsesPendingCreationDemand() {
        let book = DisplayCaptureLeaseBook()
        let displayID = CGDirectDisplayID(21001)

        book.recordPendingCreationDemand(for: displayID, kind: .preview, delta: 1)
        #expect(book.initialProfile(for: displayID, fallbackKind: .preview) == .previewOnly)

        book.recordPendingCreationDemand(for: displayID, kind: .share, delta: 1)
        #expect(book.initialProfile(for: displayID, fallbackKind: .preview) == .mixed)

        book.recordPendingCreationDemand(for: displayID, kind: .preview, delta: -1)
        #expect(book.initialProfile(for: displayID, fallbackKind: .preview) == .shareOnly)
    }

    @Test func demandSnapshotCombinesPreviewShareAndCursorState() {
        let book = DisplayCaptureLeaseBook()
        let displayID = CGDirectDisplayID(21002)

        let previewToken = book.registerToken(displayID: displayID, kind: .preview)
        let shareToken = book.registerToken(displayID: displayID, kind: .share)

        _ = book.recordAttachedPreviewSinkDelta(2, for: previewToken)
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
        let book = DisplayCaptureLeaseBook()
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
        let book = DisplayCaptureLeaseBook()
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
        let book = DisplayCaptureLeaseBook()
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
    @Test func ensureSessionExistsReusesExistingActiveSession() async throws {
        let store = DisplayCaptureSessionStore()
        let displayID = CGDirectDisplayID(22001)
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 1920, height: 1080)
        let sendableDisplay = SendableDisplay(display)
        let existingSession = SessionStoreFakeSession()
        let factoryCallCount = Mutex(0)

        store.installSessionForTesting(
            displayID: displayID,
            resolutionText: "1920 × 1080",
            session: existingSession
        )

        try await store.ensureSessionExists(
            for: sendableDisplay,
            initialProfileProvider: { _ in .shareOnly },
            performanceMode: .automatic,
            captureSessionFactory: { _, _, _ in
                factoryCallCount.withLock { $0 += 1 }
                return SessionStoreFakeSession()
            }
        )

        #expect(factoryCallCount.withLock { $0 } == 0)
        #expect(
            ObjectIdentifier(store.record(for: displayID)?.session as AnyObject)
                == ObjectIdentifier(existingSession)
        )
        #expect(store.sessionState(for: displayID) == .active)
    }

    @Test func ensureSessionExistsWaitsForDrainingSessionToFinishBeforeRecreating() async throws {
        let store = DisplayCaptureSessionStore()
        let displayID = CGDirectDisplayID(22002)
        let display = SharedMockSCDisplay.make(displayID: displayID, width: 2560, height: 1440)
        let sendableDisplay = SendableDisplay(display)
        let stopGate = SessionStoreStopGate()
        let drainingSession = SessionStoreControlledStopSession(stopGate: stopGate)
        let replacementSession = SessionStoreFakeSession()
        let factoryCallCount = Mutex(0)
        let finisher = SessionStoreDrainFinisher(store: store)

        store.installSessionForTesting(
            displayID: displayID,
            resolutionText: "2560 × 1440",
            session: drainingSession
        )
        store.beginDraining(displayID: displayID) { displayID in
            await finisher.finish(displayID: displayID, hasActiveTokens: false)
        }

        let acquireTask = Task {
            try await store.ensureSessionExists(
                for: sendableDisplay,
                initialProfileProvider: { _ in .previewOnly },
                performanceMode: .automatic,
                captureSessionFactory: { _, _, _ in
                    factoryCallCount.withLock { $0 += 1 }
                    return replacementSession
                }
            )
        }

        #expect(
            await staysTrue(timeoutNanoseconds: 50_000_000) {
                factoryCallCount.withLock { $0 } == 0
            }
        )

        await stopGate.open()
        try await acquireTask.value

        #expect(factoryCallCount.withLock { $0 } == 1)
        #expect(
            ObjectIdentifier(store.record(for: displayID)?.session as AnyObject)
                == ObjectIdentifier(replacementSession)
        )
        #expect(store.sessionState(for: displayID) == .active)
    }

    @Test func finishDrainingRemovesSessionWhenNoTokensRemain() async {
        let store = DisplayCaptureSessionStore()
        let displayID = CGDirectDisplayID(22003)
        let session = SessionStoreFakeSession()
        let finisher = SessionStoreDrainFinisher(store: store)

        store.installSessionForTesting(
            displayID: displayID,
            resolutionText: "1280 × 720",
            session: session
        )
        store.beginDraining(displayID: displayID) { displayID in
            await finisher.finish(displayID: displayID, hasActiveTokens: false)
        }

        let settled = await waitUntil {
            store.sessionState(for: displayID) == .stopped
        }

        #expect(settled)
        #expect(store.record(for: displayID) == nil)
        #expect(session.stopCallCount == 1)
    }

    @Test func finishDrainingRestoresActiveStateWhenTokensReappear() async {
        let store = DisplayCaptureSessionStore()
        let displayID = CGDirectDisplayID(22004)
        let session = SessionStoreFakeSession()
        let finisher = SessionStoreDrainFinisher(store: store)

        store.installSessionForTesting(
            displayID: displayID,
            resolutionText: "1600 × 900",
            session: session
        )
        store.beginDraining(displayID: displayID) { displayID in
            await finisher.finish(displayID: displayID, hasActiveTokens: true)
        }

        let settled = await waitUntil {
            store.sessionState(for: displayID) == .active
        }

        #expect(settled)
        #expect(store.record(for: displayID) != nil)
        #expect(session.stopCallCount == 1)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping () async -> Bool
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
