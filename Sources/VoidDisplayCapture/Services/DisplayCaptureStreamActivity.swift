import Foundation
import VoidDisplayObservability

package actor DisplayCaptureStreamActivity {
    package typealias Transition = @Sendable () async throws -> Void

    private struct Waiter {
        let shouldBeActive: Bool
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let startTransition: Transition
    private let stopTransition: Transition
    private var isActive = false
    private var desiredActive = false
    private var isDrivingTransitions = false
    private var isStopping = false
    private var terminationError: (any Error)?
    private var waiters: [UUID: Waiter] = [:]

    package init(
        start: @escaping Transition,
        stop: @escaping Transition
    ) {
        startTransition = start
        stopTransition = stop
    }

    package func setActive(_ shouldBeActive: Bool) async throws {
        if let terminationError {
            if shouldBeActive { throw terminationError }
            return
        }
        if shouldBeActive && isStopping { throw CancellationError() }
        desiredActive = shouldBeActive
        supersedeWaiters(for: !shouldBeActive)
        guard shouldBeActive != isActive || isDrivingTransitions else { return }

        let waiterID = UUID()
        try await withCheckedThrowingContinuation { continuation in
            waiters[waiterID] = Waiter(
                shouldBeActive: shouldBeActive,
                continuation: continuation
            )
            guard !isDrivingTransitions else { return }
            isDrivingTransitions = true
            Task { await self.driveTransitions() }
        }
    }

    package func stop() async throws {
        isStopping = true
        try await setActive(false)
    }

    @discardableResult
    package func didStop(error: any Error) async -> Bool {
        guard terminationError == nil else { return false }
        terminationError = error
        isActive = false
        desiredActive = false
        resolveWaitersAfterFailure(error)
        await MainActor.run {
            AppErrorMapper.logFailure("Screen capture stream stopped", error: error, logger: AppLog.capture)
        }
        return true
    }

    package func activeForTesting() -> Bool {
        isActive
    }

    private func driveTransitions() async {
        while desiredActive != isActive {
            let target = desiredActive
            do {
                if target {
                    try await startTransition()
                } else {
                    try await stopTransition()
                }
                guard terminationError == nil else {
                    isDrivingTransitions = false
                    return
                }
                isActive = target
                resumeWaiters(matching: target)
            } catch {
                desiredActive = isActive
                resolveWaitersAfterFailure(error)
                isDrivingTransitions = false
                return
            }
        }
        resumeWaiters(matching: isActive)
        isDrivingTransitions = false
    }

    private func resumeWaiters(matching state: Bool) {
        let matchingIDs = waiters.compactMap { id, waiter in
            waiter.shouldBeActive == state ? id : nil
        }
        for id in matchingIDs {
            waiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    private func supersedeWaiters(for state: Bool) {
        let supersededIDs = waiters.compactMap { id, waiter in
            waiter.shouldBeActive == state ? id : nil
        }
        for id in supersededIDs {
            waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
        }
    }

    private func resolveWaitersAfterFailure(_ error: any Error) {
        let pending = waiters.values
        waiters.removeAll(keepingCapacity: true)
        for waiter in pending {
            if waiter.shouldBeActive == isActive {
                waiter.continuation.resume()
            } else {
                waiter.continuation.resume(throwing: error)
            }
        }
    }
}
