import Foundation

nonisolated struct ActiveVirtualDisplayTransactionKey: Hashable {
    let kind: DisplayRuntimeTransactionKind
    let configID: UUID
}

nonisolated struct ActiveVirtualDisplayCoalescibleTail: Sendable {
    let key: ActiveVirtualDisplayTransactionKey
    let transactionID: DisplayRuntimeTransactionID
    let task: Task<DisplayRuntimeVirtualDisplayRebuildTransactionResult, Error>
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
        if let coalescibleTail = coalescibleVirtualDisplayTransactionTail,
           coalescibleTail.key == key {
            incrementCoalescedRequestCount(transactionID: coalescibleTail.transactionID)
            await observabilityRecorder?.refreshSnapshot(reason: .displayRuntimeTransactionChanged)
            return try await coalescibleTail.task.value
        }
        coalescibleVirtualDisplayTransactionTail = nil

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
                if self.coalescibleVirtualDisplayTransactionTail?.transactionID == context.transactionID {
                    self.coalescibleVirtualDisplayTransactionTail = nil
                }
            }
            if let previousTail {
                await previousTail.value
            }
            return try await execute(context)
        }
        virtualDisplayTransactionQueueTail = Task { @MainActor in
            _ = try? await task.value
        }
        coalescibleVirtualDisplayTransactionTail = ActiveVirtualDisplayCoalescibleTail(
            key: key,
            transactionID: context.transactionID,
            task: task
        )
        await observabilityRecorder?.refreshSnapshot(reason: .displayRuntimeTransactionChanged)

        return try await task.value
    }

    func enqueueUncoalescedVirtualDisplayEditTransaction(
        context: ActiveVirtualDisplayTransactionContext,
        saveGate: DisplayRuntimeAsyncGate<DisplayRuntimeVirtualDisplayEditRebuildSaveGateResult>,
        execute: @escaping @MainActor () async -> DisplayRuntimeVirtualDisplayRebuildTransactionResult
    ) async -> DisplayRuntimeVirtualDisplayEditRebuildTransactionHandle {
        coalescibleVirtualDisplayTransactionTail = nil
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
        coalescibleVirtualDisplayTransactionTail = nil
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
        coalescibleVirtualDisplayTransactionTail = nil
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
