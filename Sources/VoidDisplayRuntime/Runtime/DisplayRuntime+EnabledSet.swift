import Foundation

@MainActor
extension DisplayRuntime {
    package var isApplyingVirtualDisplayEnabledSet: Bool {
        activeTransactionTracesByID.values.contains { $0.kind == .virtualDisplayApplyEnabledSet }
    }

    package func prepareVirtualDisplayEnabledSet(targetConfigIDs: [UUID]) throws -> DisplayRuntimeEnabledSetPlan {
        let snapshot = makeSnapshot()
        let current = snapshot.virtualDisplay
        guard !current.configStoreHasLoadFailure else { throw DisplayRuntimeEnabledSetError.configurationUnavailable }
        let target = Set(targetConfigIDs)
        guard target.isSubset(of: Set(current.configs.map(\.id))) else {
            throw DisplayRuntimeEnabledSetError.missingConfiguration
        }
        let desired = Set(current.configs.filter(\.desiredEnabled).map(\.id))
        let running = healthyConfigIDs(current)
        let enables = target.subtracting(desired.intersection(running)).sorted(by: uuidOrder)
        let disables = desired.union(current.runningConfigIDs).union(current.managedDisplays.map(\.configID))
            .subtracting(target).sorted(by: uuidOrder)
        let consumers = enabledSetConsumers(snapshot)
        return .init(
            operationID: .init(), targetConfigIDs: target.sorted(by: uuidOrder),
            previousConfigIDs: desired.sorted(by: uuidOrder),
            steps: enables.map { .init(configID: $0, enabled: true) } + disables.map { .init(configID: $0, enabled: false) },
            interruptedConfigIDs: Set(consumers.compactMap { UUID(uuidString: $0.identity.stableID) }).sorted(by: uuidOrder),
            configs: current.configs, instances: current.managedDisplays,
            runningConfigIDs: current.runningConfigIDs, consumers: consumers
        )
    }

    package func applyVirtualDisplayEnabledSet(
        plan: DisplayRuntimeEnabledSetPlan,
        source: DisplayRuntimeTransactionSource,
        onStateSettled: @escaping @MainActor @Sendable () -> Void
    ) async throws -> DisplayRuntimeEnabledSetResult {
        guard !isApplyingVirtualDisplayEnabledSet else { throw DisplayRuntimeEnabledSetError.alreadyApplying }
        enabledSetProgress = .init(
            operationID: plan.operationID, phase: .queued, completedStepCount: 0,
            totalStepCount: plan.steps.count, currentConfigID: nil, childTransactionIDs: []
        )
        let context = ActiveVirtualDisplayInventoryTransactionContext(
            transactionID: plan.operationID, kind: .virtualDisplayApplyEnabledSet, source: source
        )
        return try await enqueueUncoalescedVirtualDisplayTransaction(context: context) {
            try await self.executeEnabledSet(plan, source: source, onStateSettled: onStateSettled)
        }
    }

    private func executeEnabledSet(
        _ plan: DisplayRuntimeEnabledSetPlan, source: DisplayRuntimeTransactionSource,
        onStateSettled: @MainActor @Sendable () -> Void
    ) async throws -> DisplayRuntimeEnabledSetResult {
        let initial = makeSnapshot()
        let current = initial.virtualDisplay
        guard !current.configStoreHasLoadFailure,
              current.configs == plan.configs,
              current.managedDisplays == plan.instances,
              current.runningConfigIDs == plan.runningConfigIDs,
              enabledSetConsumers(initial) == plan.consumers else {
            onStateSettled()
            enabledSetProgress = nil
            _ = await finalizeTransaction(
                transactionID: plan.operationID, kind: .virtualDisplayApplyEnabledSet,
                status: .cancelled, phase: .cancelled,
                failure: .init(phase: .preparing, reason: "enabled_set_plan_stale", recoverability: .retryable),
                virtualDisplayCommandSucceeded: false
            )
            throw DisplayRuntimeEnabledSetError.stalePlan
        }
        enabledSetProgress?.phase = .preparing
        await appendPhase(.preparing, transactionID: plan.operationID)
        var results: [DisplayRuntimeEnabledSetStepResult] = []
        var status = DisplayRuntimeTransactionStatus.completed
        for step in plan.steps {
            if !step.enabled, !Set(plan.targetConfigIDs).isSubset(of: healthyConfigIDs(currentVirtualDisplaySnapshot())) {
                status = .failed
                break
            }
            let child = ActiveVirtualDisplayTransactionContext(
                transactionID: .init(), kind: step.enabled ? .virtualDisplayEnable : .virtualDisplayDisable,
                configID: step.configID, source: source
            )
            enabledSetProgress?.phase = .executingVirtualDisplayCommand
            enabledSetProgress?.currentConfigID = step.configID
            enabledSetProgress?.childTransactionIDs.append(child.transactionID)
            setActiveTrace(makeInitialTrace(for: child))
            let result: DisplayRuntimeVirtualDisplayRebuildTransactionResult
            do {
                // The batch already owns the queue slot. Invoke the lifecycle executor directly.
                result = try await executeVirtualDisplayDesiredEnabledTransaction(child, desiredEnabled: step.enabled)
            } catch {
                let trace = recentTransactionTraces.first { $0.id == child.transactionID }
                result = .init(
                    transactionID: child.transactionID, kind: child.kind,
                    status: trace?.status ?? .failed, virtualDisplayCommandSucceeded: false,
                    hasSessionRecoveryFailures: trace?.status == .completedWithRecoveryFailures,
                    desiredEnabled: step.enabled
                )
            }
            onStateSettled()
            results.append(.init(step: step, result: result))
            enabledSetProgress?.completedStepCount = results.count
            if result.status != .completed || !result.virtualDisplayCommandSucceeded || result.hasSessionRecoveryFailures {
                status = result.status == .completed ? .failed : result.status
                break
            }
        }
        onStateSettled()
        let final = currentVirtualDisplaySnapshot()
        if status == .completed,
           Set(final.configs.filter(\.desiredEnabled).map(\.id)) != Set(plan.targetConfigIDs)
            || Set(final.runningConfigIDs) != Set(plan.targetConfigIDs)
            || healthyConfigIDs(final) != Set(plan.targetConfigIDs) {
            status = .failed
        }
        let result = DisplayRuntimeEnabledSetResult(
            operationID: plan.operationID, status: status, previousConfigIDs: plan.previousConfigIDs,
            targetConfigIDs: plan.targetConfigIDs, steps: results,
            skippedSteps: Array(plan.steps.dropFirst(results.count)), finalState: final
        )
        updateTrace(plan.operationID) { $0.replacing(enabledSetResult: result) }
        enabledSetProgress = nil
        _ = await finalizeTransaction(
            transactionID: plan.operationID, kind: .virtualDisplayApplyEnabledSet,
            status: status, phase: status == .completed ? .completed : (status == .cancelled ? .cancelled : .failed),
            failure: status == .completed ? nil : .init(phase: .failed, reason: "enabled_set_incomplete", recoverability: .retryable),
            virtualDisplayCommandSucceeded: status == .completed, postSnapshot: makeSnapshot()
        )
        return result
    }

    private func healthyConfigIDs(_ snapshot: DisplayRuntimeVirtualDisplaySnapshot) -> Set<UUID> {
        Set(snapshot.runningConfigIDs).intersection(snapshot.managedDisplays.filter(\.isLiveRuntime).map(\.configID))
    }

    private func enabledSetConsumers(_ snapshot: DisplayRuntimeSnapshot) -> [DisplayRuntimeEnabledSetConsumer] {
        snapshot.consumerLeases.filter { $0.surfaceIdentity.kind == .managedVirtualDisplay }
            .map { .init(id: $0.id, identity: $0.surfaceIdentity, displayID: $0.resolvedDisplayID, epoch: $0.surfaceEpoch) }
            .sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }

    private func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool { lhs.uuidString < rhs.uuidString }
}
