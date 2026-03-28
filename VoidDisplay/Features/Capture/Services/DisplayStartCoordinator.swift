import CoreGraphics
import Foundation
import Synchronization

final class DisplayStartInvalidationContext: Sendable {
    private struct State {
        var isInvalidated = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    nonisolated func invalidate() {
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

    nonisolated func isInvalidated() -> Bool {
        state.withLock { $0.isInvalidated }
    }

    nonisolated func waitForInvalidation() async {
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

    nonisolated func race<T: Sendable>(
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
final class DisplayStreamStartCoordinator {
    private struct OperationKey: Hashable {
        let kind: DisplayStartKind
        let displayID: CGDirectDisplayID
    }

    private enum OperationCompletion {
        case finished(Any)
        case invalidated
        case failed(any Error)
    }

    private final class OperationRecord {
        let token = UUID()
        let invalidationContext = DisplayStartInvalidationContext()
        var waiters: [UUID: (OperationCompletion) -> Void] = [:]
        var task: Task<Void, Never>?
    }

    private var operations: [OperationKey: OperationRecord] = [:]

    func isStarting(
        kind: DisplayStartKind,
        displayID: CGDirectDisplayID
    ) -> Bool {
        operations[OperationKey(kind: kind, displayID: displayID)] != nil
    }

    func start<Value: Sendable>(
        kind: DisplayStartKind,
        displayID: CGDirectDisplayID,
        operation: @escaping @MainActor (DisplayStartInvalidationContext) async throws -> DisplayStartOutcome<Value>
    ) async throws -> DisplayStartOutcome<Value> {
        let key = OperationKey(kind: kind, displayID: displayID)
        if let existing = operations[key] {
            return try await awaitResult(from: existing)
        }

        let record = OperationRecord()
        operations[key] = record
        let operationToken = record.token
        record.task = Task { @MainActor [weak self] in
            let completion: OperationCompletion
            do {
                let outcome = try await operation(record.invalidationContext)
                switch outcome {
                case .started(let value):
                    completion = .finished(value)
                case .invalidated:
                    completion = .invalidated
                }
            } catch {
                completion = .failed(error)
            }
            self?.complete(
                key: key,
                operationToken: operationToken,
                completion: completion
            )
        }

        return try await awaitResult(from: record)
    }

    func invalidate(
        kind: DisplayStartKind,
        displayID: CGDirectDisplayID
    ) {
        invalidate(key: OperationKey(kind: kind, displayID: displayID))
    }

    func invalidateAll(displayID: CGDirectDisplayID) {
        invalidate(kind: .monitoring, displayID: displayID)
        invalidate(kind: .sharing, displayID: displayID)
    }

    func invalidateAll(kind: DisplayStartKind) {
        let keysToInvalidate = operations.keys.filter { $0.kind == kind }
        for key in keysToInvalidate {
            invalidate(key: key)
        }
    }

    func waiterCountForTesting(
        kind: DisplayStartKind,
        displayID: CGDirectDisplayID
    ) -> Int {
        operations[OperationKey(kind: kind, displayID: displayID)]?.waiters.count ?? 0
    }

    private func awaitResult<Value: Sendable>(
        from record: OperationRecord
    ) async throws -> DisplayStartOutcome<Value> {
        try await withCheckedThrowingContinuation { continuation in
            let waiterID = UUID()
            record.waiters[waiterID] = { completion in
                switch completion {
                case .finished(let value):
                    guard let typedValue = value as? Value else {
                        continuation.resume(throwing: StartCoordinatorTypeMismatchError())
                        return
                    }
                    continuation.resume(returning: .started(typedValue))
                case .invalidated:
                    continuation.resume(returning: .invalidated)
                case .failed(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func complete(
        key: OperationKey,
        operationToken: UUID,
        completion: OperationCompletion
    ) {
        guard let record = operations[key], record.token == operationToken else { return }
        operations.removeValue(forKey: key)
        let waiters = Array(record.waiters.values)
        record.waiters.removeAll()
        for waiter in waiters {
            waiter(completion)
        }
    }

    private func invalidate(key: OperationKey) {
        guard let record = operations.removeValue(forKey: key) else { return }
        record.invalidationContext.invalidate()
        record.task?.cancel()
        let waiters = Array(record.waiters.values)
        record.waiters.removeAll()
        for waiter in waiters {
            waiter(.invalidated)
        }
    }
}
