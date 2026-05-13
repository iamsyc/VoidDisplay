import Foundation

nonisolated struct ActiveVirtualDisplayTransactionKey: Hashable {
    let kind: DisplayRuntimeTransactionKind
    let configID: UUID
}

nonisolated struct ActiveVirtualDisplayTransactionContext: Sendable {
    let transactionID: DisplayRuntimeTransactionID
    let kind: DisplayRuntimeTransactionKind
    let configID: UUID
    let source: DisplayRuntimeTransactionSource
}

nonisolated struct ActiveVirtualDisplayInventoryTransactionContext: Sendable {
    let transactionID: DisplayRuntimeTransactionID
    let kind: DisplayRuntimeTransactionKind
    let source: DisplayRuntimeTransactionSource
}

@MainActor
extension DisplayRuntime {
    func enqueueVirtualDisplayTransaction(
        kind: DisplayRuntimeTransactionKind,
        configID: UUID,
        source: DisplayRuntimeTransactionSource,
        execute: @escaping @MainActor (ActiveVirtualDisplayTransactionContext) async throws -> DisplayRuntimeVirtualDisplayRebuildTransactionResult
    ) async throws -> DisplayRuntimeVirtualDisplayRebuildTransactionResult {
        let key = ActiveVirtualDisplayTransactionKey(kind: kind, configID: configID)
        if let activeTask = activeVirtualDisplayTransactionTasksByKey[key],
           let transactionID = activeVirtualDisplayTransactionIDsByKey[key] {
            incrementCoalescedRequestCount(transactionID: transactionID)
            await observabilityRecorder?.refreshSnapshot(reason: .displayRuntimeTransactionChanged)
            return try await activeTask.value
        }

        let context = ActiveVirtualDisplayTransactionContext(
            transactionID: DisplayRuntimeTransactionID(),
            kind: kind,
            configID: configID,
            source: source
        )
        let previousTail = virtualDisplayTransactionQueueTail
        setActiveTrace(makeInitialTrace(for: context))

        let task = Task { @MainActor in
            defer {
                self.activeVirtualDisplayTransactionTasksByKey[key] = nil
                self.activeVirtualDisplayTransactionIDsByKey[key] = nil
            }
            if let previousTail {
                await previousTail.value
            }
            return try await execute(context)
        }
        virtualDisplayTransactionQueueTail = Task { @MainActor in
            _ = try? await task.value
        }
        activeVirtualDisplayTransactionTasksByKey[key] = task
        activeVirtualDisplayTransactionIDsByKey[key] = context.transactionID
        await observabilityRecorder?.refreshSnapshot(reason: .displayRuntimeTransactionChanged)

        return try await task.value
    }

    func enqueueUncoalescedVirtualDisplayEditTransaction(
        context: ActiveVirtualDisplayTransactionContext,
        saveGate: DisplayRuntimeAsyncGate<DisplayRuntimeVirtualDisplayEditRebuildSaveGateResult>,
        execute: @escaping @MainActor () async -> DisplayRuntimeVirtualDisplayRebuildTransactionResult
    ) async -> DisplayRuntimeVirtualDisplayEditRebuildTransactionHandle {
        let terminalResultGate = DisplayRuntimeAsyncGate<DisplayRuntimeVirtualDisplayRebuildTransactionResult>()
        let previousTail = virtualDisplayTransactionQueueTail

        setActiveTrace(makeInitialTrace(for: context))
        let task = Task { @MainActor in
            if let previousTail {
                await previousTail.value
            }
            let result = await execute()
            terminalResultGate.succeed(result)
        }
        virtualDisplayTransactionQueueTail = Task { @MainActor in
            await task.value
        }
        await observabilityRecorder?.refreshSnapshot(reason: .displayRuntimeTransactionChanged)

        return DisplayRuntimeVirtualDisplayEditRebuildTransactionHandle(
            transactionID: context.transactionID,
            saveGate: saveGate,
            terminalResultGate: terminalResultGate
        )
    }

    func enqueueUncoalescedVirtualDisplayTransaction<Result: Sendable>(
        context: ActiveVirtualDisplayInventoryTransactionContext,
        execute: @escaping @MainActor () async throws -> Result
    ) async throws -> Result {
        let previousTail = virtualDisplayTransactionQueueTail
        setActiveTrace(makeInitialTrace(
            transactionID: context.transactionID,
            kind: context.kind,
            source: context.source
        ))
        let task = Task { @MainActor in
            if let previousTail {
                await previousTail.value
            }
            return try await execute()
        }
        virtualDisplayTransactionQueueTail = Task { @MainActor in
            _ = try? await task.value
        }
        await observabilityRecorder?.refreshSnapshot(reason: .displayRuntimeTransactionChanged)
        return try await task.value
    }

    func enqueueUncoalescedVirtualDisplayTransaction<Result: Sendable>(
        context: ActiveVirtualDisplayTransactionContext,
        execute: @escaping @MainActor () async throws -> Result
    ) async throws -> Result {
        let previousTail = virtualDisplayTransactionQueueTail
        setActiveTrace(makeInitialTrace(for: context))
        let task = Task { @MainActor in
            if let previousTail {
                await previousTail.value
            }
            return try await execute()
        }
        virtualDisplayTransactionQueueTail = Task { @MainActor in
            _ = try? await task.value
        }
        await observabilityRecorder?.refreshSnapshot(reason: .displayRuntimeTransactionChanged)
        return try await task.value
    }
}
