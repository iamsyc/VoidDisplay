import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation

@MainActor
package final class PrimaryDisplayFallbackCoordinator {
    package typealias Sleep = @Sendable (_ duration: Duration) async -> Void

    private let pollInterval: Duration
    private let recoveryAttemptIntervalCycles: Int
    private let sleep: Sleep

    private var fallbackTask: Task<Void, Never>?

    package init(
        pollInterval: Duration = .milliseconds(500),
        recoveryAttemptIntervalCycles: Int = 10,
        sleep: Sleep? = nil
    ) {
        self.pollInterval = pollInterval
        self.recoveryAttemptIntervalCycles = max(1, recoveryAttemptIntervalCycles)
        self.sleep = sleep ?? { duration in
            try? await Task.sleep(for: duration)
        }
    }

    package var isRunning: Bool {
        fallbackTask != nil
    }

    package func startIfNeeded(
        onTick: @escaping @MainActor () -> Void,
        attemptRecovery: @escaping @MainActor () -> Bool,
        onRecovered: @escaping @MainActor () -> Void
    ) {
        guard fallbackTask == nil else { return }

        fallbackTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var cycle = 0
            while !Task.isCancelled {
                await self.sleep(self.pollInterval)
                guard !Task.isCancelled else { break }

                onTick()

                cycle += 1
                if cycle % self.recoveryAttemptIntervalCycles != 0 {
                    continue
                }

                if attemptRecovery() {
                    onRecovered()
                    self.stop()
                    break
                }
            }
        }
    }

    package func stop() {
        fallbackTask?.cancel()
        fallbackTask = nil
    }

    deinit {
        fallbackTask?.cancel()
    }
}
