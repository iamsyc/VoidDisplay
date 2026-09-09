@testable import VoidDisplayCapture
import Synchronization
import Testing

struct DisplayCaptureStreamActivityTests {
    @Test func finalStopRejectsLateDemandWhileWaitingForCaptureToStop() async throws {
        let stopGate = SuspendedTransition()
        let activity = DisplayCaptureStreamActivity(start: {}, stop: { await stopGate.suspend() })
        try await activity.setActive(true)
        let stopTask = Task { try await activity.stop() }
        await stopGate.waitUntilSuspended()

        let lateStart = Task { try await activity.setActive(true) }
        await stopGate.resume()
        await #expect(throws: CancellationError.self) { try await lateStart.value }
        try await stopTask.value
        #expect(await activity.activeForTesting() == false)
        await #expect(throws: CancellationError.self) { try await activity.setActive(true) }
    }

    @Test func unexpectedStopInvalidatesActiveStateAndPreventsReuse() async throws {
        struct StreamFailure: Error {}
        let transitions = Mutex<[String]>([])
        let activity = DisplayCaptureStreamActivity(
            start: { transitions.withLock { $0.append("start") } },
            stop: { transitions.withLock { $0.append("stop") } }
        )
        try await activity.setActive(true)
        #expect(await activity.activeForTesting())
        await activity.didStop(error: StreamFailure())
        #expect(await activity.activeForTesting() == false)
        await #expect(throws: StreamFailure.self) { try await activity.setActive(true) }
        try await activity.stop()
        #expect(transitions.withLock { $0 } == ["start"])
    }

    @Test func unexpectedStopDuringStartCannotBeOverwrittenByLateCompletion() async throws {
        struct StreamFailure: Error {}
        let gate = SuspendedTransition()
        let activity = DisplayCaptureStreamActivity(start: { await gate.suspend() }, stop: {})
        let start = Task { try await activity.setActive(true) }
        await gate.waitUntilSuspended()
        await activity.didStop(error: StreamFailure())
        await gate.resume()
        await #expect(throws: StreamFailure.self) { try await start.value }
        #expect(await activity.activeForTesting() == false)
    }

    @Test func startsAndStopsOnlyAcrossDemandBoundaries() async throws {
        let transitions = Mutex<[String]>([])
        let activity = DisplayCaptureStreamActivity(
            start: { transitions.withLock { $0.append("start") } },
            stop: { transitions.withLock { $0.append("stop") } }
        )

        try await activity.setActive(false)
        try await activity.setActive(true)
        try await activity.setActive(true)
        try await activity.setActive(false)
        try await activity.setActive(false)

        #expect(transitions.withLock { $0 } == ["start", "stop"])
        #expect(await activity.activeForTesting() == false)
    }

    @Test func failedTransitionPreservesLastConfirmedState() async throws {
        struct TransitionFailure: Error {}

        let activity = DisplayCaptureStreamActivity(
            start: { throw TransitionFailure() },
            stop: {}
        )

        await #expect(throws: TransitionFailure.self) {
            try await activity.setActive(true)
        }
        #expect(await activity.activeForTesting() == false)
    }

    @Test func stopRequestedDuringStartWaitsForCompensatingStop() async throws {
        let startGate = SuspendedTransition()
        let transitions = Mutex<[String]>([])
        let activity = DisplayCaptureStreamActivity(
            start: {
                transitions.withLock { $0.append("start") }
                await startGate.suspend()
            },
            stop: { transitions.withLock { $0.append("stop") } }
        )

        let startTask = Task { try await activity.setActive(true) }
        await startGate.waitUntilSuspended()
        let stopTask = Task { try await activity.setActive(false) }
        await #expect(throws: CancellationError.self) {
            try await startTask.value
        }
        await startGate.resume()
        try await stopTask.value

        #expect(transitions.withLock { $0 } == ["start", "stop"])
        #expect(await activity.activeForTesting() == false)
    }

    @Test func latestDemandSupersedesIntermediateWaiterDuringStart() async throws {
        let startGate = SuspendedTransition()
        let transitions = Mutex<[String]>([])
        let activity = DisplayCaptureStreamActivity(
            start: {
                transitions.withLock { $0.append("start") }
                await startGate.suspend()
            },
            stop: { transitions.withLock { $0.append("stop") } }
        )

        let firstStart = Task { try await activity.setActive(true) }
        await startGate.waitUntilSuspended()
        let intermediateStop = Task { try await activity.setActive(false) }
        await #expect(throws: CancellationError.self) {
            try await firstStart.value
        }
        let finalStart = Task { try await activity.setActive(true) }
        await #expect(throws: CancellationError.self) {
            try await intermediateStop.value
        }
        await startGate.resume()
        try await finalStart.value

        #expect(transitions.withLock { $0 } == ["start"])
        #expect(await activity.activeForTesting())
    }

    @Test func stabilityRepeatedDemandChurnLeavesStreamInactive() async throws {
        let transitions = Mutex((starts: 0, stops: 0))
        let activity = DisplayCaptureStreamActivity(
            start: { transitions.withLock { $0.starts += 1 } },
            stop: { transitions.withLock { $0.stops += 1 } }
        )

        for _ in 0..<1_000 {
            try await activity.setActive(true)
            try await activity.setActive(false)
        }

        #expect(transitions.withLock { $0.starts } == 1_000)
        #expect(transitions.withLock { $0.stops } == 1_000)
        #expect(await activity.activeForTesting() == false)
    }
}

private actor SuspendedTransition {
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSuspended() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
