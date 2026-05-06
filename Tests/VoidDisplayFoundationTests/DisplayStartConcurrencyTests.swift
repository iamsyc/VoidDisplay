@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import CoreGraphics
import Dispatch
import Testing

private actor DisplayStartCoordinatorGate {
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

private func waitForDisplayStartCoordinatorGate(
    _ gate: DisplayStartCoordinatorGate,
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

@Suite(.serialized)
struct DisplayStartInvalidationContextTests {
    @Test func raceSuccessDoesNotRetainWaiters() async throws {
        let context = DisplayStartInvalidationContext()

        let outcome = try await context.race { 42 }

        guard case .started(let value) = outcome else {
            Issue.record("Expected race to return started outcome.")
            return
        }

        #expect(value == 42)
        #expect(context.waiterCountForTesting == 0)
        #expect(context.isInvalidated() == false)
    }

    @Test func raceReturnsInvalidatedWhenInvalidationWins() async throws {
        let context = DisplayStartInvalidationContext()

        let task = Task {
            try await context.race {
                try await Task.sleep(for: .seconds(30))
                return 7
            }
        }

        context.invalidate()
        let outcome = try await task.value

        if case .invalidated = outcome {
        } else {
            Issue.record("Expected invalidated outcome.")
        }
        #expect(context.waiterCountForTesting == 0)
    }

    @Test func waitForInvalidationCancellationRemovesWaiter() async {
        let context = DisplayStartInvalidationContext()

        let task = Task {
            await context.waitForInvalidation()
        }

        #expect(await waitUntil { context.waiterCountForTesting == 1 })

        task.cancel()
        await task.value

        #expect(await waitUntil { context.waiterCountForTesting == 0 })
    }

    @Test func repeatedRaceCallsLeaveNoWaitersBehind() async throws {
        let context = DisplayStartInvalidationContext()

        for expected in 0..<10 {
            let outcome = try await context.race { expected }
            guard case .started(let value) = outcome else {
                Issue.record("Expected race iteration \(expected) to succeed.")
                return
            }
            #expect(value == expected)
            #expect(context.waiterCountForTesting == 0)
        }
    }
}

@Suite(.serialized)
@MainActor
struct DisplayStreamStartCoordinatorTests {
    @Test func invalidateReturnsInvalidatedBeforeBlockedOperationCompletes() async throws {
        let coordinator = DisplayStreamStartCoordinator()
        let gate = DisplayStartCoordinatorGate()
        let displayID: CGDirectDisplayID = 901

        let task = Task { @MainActor in
            try await coordinator.start(kind: .sharing, displayID: displayID) { _ in
                await gate.wait()
                return .started(1)
            }
        }

        #expect(await waitForDisplayStartCoordinatorGate(gate, count: 1))

        coordinator.invalidate(kind: .sharing, displayID: displayID)
        let outcome = try await task.value

        if case .invalidated = outcome {
        } else {
            Issue.record("Expected invalidated outcome.")
        }

        await gate.releaseOne()
        #expect(coordinator.isStarting(kind: .sharing, displayID: displayID) == false)
    }

    @Test func invalidatedOldOperationCannotCompleteNewOperationRecord() async throws {
        let coordinator = DisplayStreamStartCoordinator()
        let firstGate = DisplayStartCoordinatorGate()
        let secondGate = DisplayStartCoordinatorGate()
        let displayID: CGDirectDisplayID = 902

        let firstTask = Task { @MainActor in
            try await coordinator.start(kind: .sharing, displayID: displayID) { _ in
                await firstGate.wait()
                return .started(1)
            }
        }
        #expect(await waitForDisplayStartCoordinatorGate(firstGate, count: 1))

        coordinator.invalidate(kind: .sharing, displayID: displayID)
        let firstOutcome = try await firstTask.value
        if case .invalidated = firstOutcome {
        } else {
            Issue.record("Expected first outcome to be invalidated.")
        }

        let secondTask = Task { @MainActor in
            try await coordinator.start(kind: .sharing, displayID: displayID) { _ in
                await secondGate.wait()
                return .started(2)
            }
        }
        #expect(await waitForDisplayStartCoordinatorGate(secondGate, count: 1))

        await firstGate.releaseOne()
        await Task.yield()

        #expect(coordinator.isStarting(kind: .sharing, displayID: displayID))

        await secondGate.releaseOne()
        let secondOutcome = try await secondTask.value

        guard case .started(let value) = secondOutcome else {
            Issue.record("Expected second operation to succeed.")
            return
        }

        #expect(value == 2)
        #expect(coordinator.isStarting(kind: .sharing, displayID: displayID) == false)
    }
}
