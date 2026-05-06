import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import Synchronization
package final class DisplayCaptureDemandDriver: @unchecked Sendable {
    typealias ImmediateDemandApplier = @Sendable (DisplayCaptureDemandSnapshot) async throws -> Bool
    typealias ConfigurationApplier = @Sendable (DisplayCaptureConfiguration) async throws -> Bool
    typealias ConfigurationAppliedHandler = @Sendable (DisplayCaptureConfiguration) -> Void
    typealias ConfigurationFailureHandler = @Sendable (any Error) -> Void

    private struct State {
        var configurationCoordinator: DisplayCaptureConfigurationCoordinatorState
        var taskLifetime = DisplayCaptureTaskLifetimeState()
        var pendingTaskNonce: UInt64 = 0
        var pendingConfigurationTask: Task<Void, Never>?
        var activeApplyTask: Task<Void, Never>?
    }

    private let minimumDwellNanoseconds: UInt64
    private let currentTimeNanoseconds: @Sendable () -> UInt64
    private let applyImmediateDemandClosure: ImmediateDemandApplier
    private let applyConfigurationClosure: ConfigurationApplier
    private let onConfigurationApplied: ConfigurationAppliedHandler
    private let onConfigurationFailure: ConfigurationFailureHandler?
    private let state: Mutex<State>

    nonisolated init(
        initialConfiguration: DisplayCaptureConfiguration,
        initialDemand: DisplayCaptureDemandSnapshot,
        captureSizeContext: DisplayCaptureSizeContext = .defaultShared,
        minimumDwellNanoseconds: UInt64,
        currentTimeNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        applyImmediateDemand: @escaping ImmediateDemandApplier,
        applyConfiguration: @escaping ConfigurationApplier,
        onConfigurationApplied: @escaping ConfigurationAppliedHandler = { _ in },
        onConfigurationFailure: ConfigurationFailureHandler? = nil
    ) {
        self.minimumDwellNanoseconds = minimumDwellNanoseconds
        self.currentTimeNanoseconds = currentTimeNanoseconds
        self.applyImmediateDemandClosure = applyImmediateDemand
        self.applyConfigurationClosure = applyConfiguration
        self.onConfigurationApplied = onConfigurationApplied
        self.onConfigurationFailure = onConfigurationFailure
        self.state = Mutex(
            State(
                configurationCoordinator: DisplayCaptureConfigurationCoordinatorState(
                    committedConfiguration: initialConfiguration,
                    demand: initialDemand,
                    captureSizeContext: captureSizeContext
                )
            )
        )
    }

    nonisolated func setDemand(_ demand: DisplayCaptureDemandSnapshot) async throws {
        _ = try await applyImmediateDemandClosure(demand)
        scheduleConfigurationDecision { state, nowNs, minimumDwellNanoseconds in
            state.configurationCoordinator.updateDemand(
                demand,
                nowNs: nowNs,
                minimumDwellNanoseconds: minimumDwellNanoseconds
            )
        }
    }

    nonisolated func recordPreviewPerformanceSample(_ sample: DisplayPreviewPerformanceSample) {
        scheduleConfigurationDecision { state, nowNs, minimumDwellNanoseconds in
            state.configurationCoordinator.recordPreviewPerformanceSample(
                sample,
                nowNs: nowNs,
                minimumDwellNanoseconds: minimumDwellNanoseconds
            )
        }
    }

    nonisolated func cancelAll() {
        state.withLock { state in
            _ = state.taskLifetime.invalidateAllTasks()
            state.pendingConfigurationTask?.cancel()
            state.pendingConfigurationTask = nil
            state.activeApplyTask?.cancel()
            state.activeApplyTask = nil
        }
    }

    nonisolated private func scheduleConfigurationDecision(
        _ decisionProvider: (
            inout State,
            UInt64,
            UInt64
        ) -> DisplayCaptureConfigurationDecision
    ) {
        let decision = state.withLock { state -> (DisplayCaptureConfigurationDecision, UInt64) in
            state.pendingConfigurationTask?.cancel()
            state.pendingConfigurationTask = nil
            state.pendingTaskNonce &+= 1
            let decision = decisionProvider(
                &state,
                currentTimeNanoseconds(),
                minimumDwellNanoseconds
            )
            return (decision, state.pendingTaskNonce)
        }
        handleConfigurationDecision(decision.0, schedulingNonce: decision.1)
    }

    nonisolated private func handleConfigurationDecision(
        _ decision: DisplayCaptureConfigurationDecision,
        schedulingNonce: UInt64
    ) {
        switch decision {
        case .noChange:
            return
        case .applyNow(let configuration):
            let executionGeneration = state.withLock { $0.taskLifetime.currentGeneration }
            let task = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.applyConfiguration(
                    configuration: configuration,
                    executionGeneration: executionGeneration
                )
            }
            state.withLock { state in
                if state.taskLifetime.allowsExecution(for: executionGeneration) {
                    state.activeApplyTask = task
                } else {
                    task.cancel()
                }
            }
        case .applyAfter(_, let delayNanoseconds):
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                self?.resumeDemandDrivenConfigurationEvaluation(schedulingNonce: schedulingNonce)
            }
            state.withLock { state in
                if state.pendingTaskNonce == schedulingNonce {
                    state.pendingConfigurationTask = task
                } else {
                    task.cancel()
                }
            }
        }
    }

    nonisolated private func resumeDemandDrivenConfigurationEvaluation(schedulingNonce: UInt64) {
        let decision = state.withLock { state -> (DisplayCaptureConfigurationDecision, UInt64)? in
            guard state.pendingTaskNonce == schedulingNonce else {
                return nil
            }
            state.pendingConfigurationTask = nil
            state.pendingTaskNonce &+= 1
            let decision = state.configurationCoordinator.resumeScheduledTransition(
                nowNs: currentTimeNanoseconds(),
                minimumDwellNanoseconds: minimumDwellNanoseconds
            )
            return (decision, state.pendingTaskNonce)
        }
        guard let decision else { return }
        handleConfigurationDecision(decision.0, schedulingNonce: decision.1)
    }

    nonisolated private func applyConfiguration(
        configuration: DisplayCaptureConfiguration,
        executionGeneration: UInt64
    ) async {
        guard isExecutionAllowed(for: executionGeneration) else { return }

        let changed: Bool
        do {
            try Task.checkCancellation()
            guard isExecutionAllowed(for: executionGeneration) else { return }
            changed = try await applyConfigurationClosure(configuration)
        } catch is CancellationError {
            finishDiscardedConfigurationApply(executionGeneration: executionGeneration)
            return
        } catch {
            finishDiscardedConfigurationApply(executionGeneration: executionGeneration)
            onConfigurationFailure?(error)
            return
        }

        guard changed else {
            finishDiscardedConfigurationApply(executionGeneration: executionGeneration)
            return
        }

        guard isExecutionAllowed(for: executionGeneration) else { return }
        onConfigurationApplied(configuration)

        let decision = state.withLock { state -> (DisplayCaptureConfigurationDecision, UInt64)? in
            guard state.taskLifetime.allowsExecution(for: executionGeneration) else {
                return nil
            }
            state.pendingConfigurationTask?.cancel()
            state.pendingConfigurationTask = nil
            state.activeApplyTask = nil
            state.pendingTaskNonce &+= 1
            let decision = state.configurationCoordinator.finishAppliedTransition(
                at: currentTimeNanoseconds(),
                minimumDwellNanoseconds: minimumDwellNanoseconds
            )
            return (decision, state.pendingTaskNonce)
        }
        guard let decision else { return }
        handleConfigurationDecision(decision.0, schedulingNonce: decision.1)
    }

    nonisolated private func isExecutionAllowed(for generation: UInt64) -> Bool {
        state.withLock { state in
            state.taskLifetime.allowsExecution(for: generation)
        }
    }

    nonisolated private func finishDiscardedConfigurationApply(executionGeneration: UInt64) {
        state.withLock { state in
            guard state.taskLifetime.allowsExecution(for: executionGeneration) else { return }
            state.activeApplyTask = nil
            state.configurationCoordinator.failAppliedTransition()
        }
    }
}
