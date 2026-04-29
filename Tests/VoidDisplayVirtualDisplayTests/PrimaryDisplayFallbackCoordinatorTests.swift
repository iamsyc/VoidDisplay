@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayFoundation
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct PrimaryDisplayFallbackCoordinatorTests {

    @Test func coordinatorAttemptsRecoveryByCycleAndStopsAfterRecovery() async {
        let coordinator = PrimaryDisplayFallbackCoordinator(
            pollInterval: .milliseconds(1),
            recoveryAttemptIntervalCycles: 3,
            sleep: { _ in await Task.yield() }
        )

        var tickCount = 0
        var recoveryAttemptCount = 0
        coordinator.startIfNeeded(
            onTick: {
                tickCount += 1
            },
            attemptRecovery: {
                recoveryAttemptCount += 1
                return recoveryAttemptCount >= 2
            },
            onRecovered: {}
        )

        let stopped = await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            !coordinator.isRunning
        }

        #expect(stopped)
        #expect(recoveryAttemptCount == 2)
        #expect(tickCount >= 6)
    }

    @Test func coordinatorDoesNotStartTwiceAndCanBeStopped() async {
        let coordinator = PrimaryDisplayFallbackCoordinator(
            pollInterval: .milliseconds(2),
            recoveryAttemptIntervalCycles: 10,
            sleep: { _ in await Task.yield() }
        )

        var tickCount = 0
        coordinator.startIfNeeded(
            onTick: {
                tickCount += 1
            },
            attemptRecovery: { false },
            onRecovered: {}
        )

        coordinator.startIfNeeded(
            onTick: {
                tickCount += 1000
            },
            attemptRecovery: { true },
            onRecovered: {}
        )

        let ticked = await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            tickCount > 0
        }
        #expect(ticked)

        coordinator.stop()
        let stopped = await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            !coordinator.isRunning
        }
        #expect(stopped)

        let snapshot = tickCount
        #expect(await staysTrue(timeoutNanoseconds: 20_000_000) { tickCount == snapshot })
    }
}
