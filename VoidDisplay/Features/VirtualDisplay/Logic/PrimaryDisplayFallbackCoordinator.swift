import Foundation

@MainActor
final class PrimaryDisplayFallbackCoordinator {
    typealias Sleep = @Sendable (_ nanoseconds: UInt64) async -> Void

    private let pollIntervalNanoseconds: UInt64
    private let recoveryAttemptIntervalCycles: Int
    private let sleep: Sleep

    private var fallbackTask: Task<Void, Never>?

    init(
        pollIntervalNanoseconds: UInt64 = 500_000_000,
        recoveryAttemptIntervalCycles: Int = 10,
        sleep: Sleep? = nil
    ) {
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.recoveryAttemptIntervalCycles = max(1, recoveryAttemptIntervalCycles)
        self.sleep = sleep ?? { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    }

    var isRunning: Bool {
        fallbackTask != nil
    }

    func startIfNeeded(
        onTick: @escaping @MainActor () -> Void,
        attemptRecovery: @escaping @MainActor () -> Bool,
        onRecovered: @escaping @MainActor () -> Void
    ) {
        guard fallbackTask == nil else { return }

        fallbackTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var cycle = 0
            while !Task.isCancelled {
                await self.sleep(self.pollIntervalNanoseconds)
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

    func stop() {
        fallbackTask?.cancel()
        fallbackTask = nil
    }

    deinit {
        fallbackTask?.cancel()
    }
}
