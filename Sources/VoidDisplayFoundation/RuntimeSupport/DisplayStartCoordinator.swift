import CoreGraphics
import Foundation
import Synchronization

package enum DisplayStartOutcome<Value: Sendable>: Sendable {
    case started(Value)
    case invalidated
}

package final class DisplayStartInvalidationContext: Sendable {
    private struct State {
        var isInvalidated = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    package nonisolated func invalidate() {
        let pendingWaiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.isInvalidated else { return [] }
            state.isInvalidated = true
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }

    package nonisolated func isInvalidated() -> Bool {
        state.withLock { $0.isInvalidated }
    }

    package nonisolated func waitForInvalidation() async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResumeImmediately = state.withLock { state -> Bool in
                    if state.isInvalidated || Task.isCancelled {
                        return true
                    }
                    state.waiters[waiterID] = continuation
                    return false
                }
                if shouldResumeImmediately {
                    continuation.resume()
                    return
                }

                if Task.isCancelled {
                    let cancelledWaiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                        state.waiters.removeValue(forKey: waiterID)
                    }
                    cancelledWaiter?.resume()
                }
            }
        } onCancel: {
            let cancelledWaiter = self.state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.waiters.removeValue(forKey: waiterID)
            }
            cancelledWaiter?.resume()
        }
    }

    package nonisolated func race<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> DisplayStartOutcome<T> {
        if isInvalidated() {
            return .invalidated
        }

        return try await withThrowingTaskGroup(of: DisplayStartOutcome<T>.self) { group in
            group.addTask {
                .started(try await operation())
            }
            group.addTask {
                await self.waitForInvalidation()
                try Task.checkCancellation()
                return .invalidated
            }

            do {
                guard let firstResult = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                while (try? await group.next()) != nil {}
                return firstResult
            } catch {
                group.cancelAll()
                while (try? await group.next()) != nil {}
                throw error
            }
        }
    }

    nonisolated var waiterCountForTesting: Int {
        state.withLock { $0.waiters.count }
    }
}

@MainActor
package final class DisplayStreamStartCoordinator<Value: Sendable> {
    package init() {}

    private final class OperationRecord {
        let token = UUID()
        let invalidationContext = DisplayStartInvalidationContext()
        var waiters: [CheckedContinuation<DisplayStartOutcome<Value>, any Error>] = []
        var task: Task<Void, Never>?
    }

    private var operations: [CGDirectDisplayID: OperationRecord] = [:]

    package func isStarting(displayID: CGDirectDisplayID) -> Bool {
        operations[displayID] != nil
    }

    package func start(
        displayID: CGDirectDisplayID,
        operation: @escaping @MainActor (DisplayStartInvalidationContext) async throws -> DisplayStartOutcome<Value>
    ) async throws -> DisplayStartOutcome<Value> {
        if let existing = operations[displayID] {
            return try await awaitResult(from: existing)
        }

        let record = OperationRecord()
        operations[displayID] = record
        let operationToken = record.token
        record.task = Task { @MainActor [weak self] in
            let completion: Result<DisplayStartOutcome<Value>, any Error>
            do {
                completion = .success(try await operation(record.invalidationContext))
            } catch {
                completion = .failure(error)
            }
            self?.complete(
                displayID: displayID,
                operationToken: operationToken,
                completion: completion
            )
        }

        return try await awaitResult(from: record)
    }

    package func invalidate(displayID: CGDirectDisplayID) {
        guard let record = operations.removeValue(forKey: displayID) else { return }
        record.invalidationContext.invalidate()
        record.task?.cancel()
        let waiters = record.waiters
        record.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: .invalidated)
        }
    }

    package func invalidateAll() {
        for displayID in Array(operations.keys) {
            invalidate(displayID: displayID)
        }
    }

    package func waiterCountForTesting(displayID: CGDirectDisplayID) -> Int {
        operations[displayID]?.waiters.count ?? 0
    }

    private func awaitResult(
        from record: OperationRecord
    ) async throws -> DisplayStartOutcome<Value> {
        try await withCheckedThrowingContinuation { continuation in
            record.waiters.append(continuation)
        }
    }

    private func complete(
        displayID: CGDirectDisplayID,
        operationToken: UUID,
        completion: Result<DisplayStartOutcome<Value>, any Error>
    ) {
        guard let record = operations[displayID], record.token == operationToken else { return }
        operations.removeValue(forKey: displayID)
        let waiters = record.waiters
        record.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(with: completion)
        }
    }
}
