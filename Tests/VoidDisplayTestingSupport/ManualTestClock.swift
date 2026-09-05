import Foundation
import Synchronization

/// A clock advanced by the test, with observable suspended work and cancellation cleanup.
package final class ManualTestClock: Clock, Sendable {
    package typealias Instant = ContinuousClock.Instant
    package typealias Duration = Swift.Duration

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct State {
        var now = ContinuousClock.now
        var sleepers: [UUID: Sleeper] = [:]
    }
    private let state = Mutex(State())
    package init() {}
    package var now: Instant { state.withLock { $0.now } }
    package var minimumResolution: Duration { .nanoseconds(1) }
    package var pendingSleepCount: Int { state.withLock { $0.sleepers.count } }

    package func sleep(until deadline: Instant, tolerance _: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                state.withLock { state in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if deadline <= state.now {
                        continuation.resume()
                    } else {
                        state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    }
                }
            }
        } onCancel: {
            self.state.withLock { $0.sleepers.removeValue(forKey: id) }?
                .continuation.resume(throwing: CancellationError())
        }
    }

    package func advance(by duration: Duration) {
        precondition(duration >= .zero)
        let ready = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let ready = state.sleepers.filter { $0.value.deadline <= state.now }
            for id in ready.keys { state.sleepers.removeValue(forKey: id) }
            return Array(ready.values)
        }
        for sleeper in ready { sleeper.continuation.resume() }
    }
}
