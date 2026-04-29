@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import CoreGraphics
import Synchronization
import Testing

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

    nonisolated let shareFrameConsumer: any DisplayShareFrameConsumer = TestDisplayShareFrameConsumer()

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

struct DisplayShareSubscriptionTests {
    @Test func shareSubscriptionDoesNotReleaseCursorOverrideWhenRetainFails() async throws {
        let session = CursorOverrideTrackingSession(retainFailures: [true])
        let cancelCount = Mutex(0)
        let subscription = DisplayShareSubscription(
            displayID: CGDirectDisplayID(12001),
            shareFrameConsumer: session.shareFrameConsumer,
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
            shareFrameConsumer: session.shareFrameConsumer,
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
            shareFrameConsumer: session.shareFrameConsumer,
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
            shareFrameConsumer: session.shareFrameConsumer,
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
}
