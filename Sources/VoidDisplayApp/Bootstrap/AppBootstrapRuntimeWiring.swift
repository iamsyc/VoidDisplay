import VoidDisplayCapture
import VoidDisplayRuntime
import VoidDisplayVirtualDisplay
import Foundation

extension AppBootstrap {
    static func wireRuntime(
        runtime: AppBootstrapRuntimeBundle,
        captureSharing: AppBootstrapCaptureSharingBundle,
        capturePerformancePreferences: CapturePerformancePreferences
    ) {
        configureCapturePerformanceSync(
            runtime: runtime.displayRuntime,
            captureRegistry: captureSharing.captureRegistry,
            preferences: capturePerformancePreferences
        )
        runtime.sharingAdapter.configureLANWebViewDemandSync(runtime: runtime.displayRuntime)
    }

    private static func configureCapturePerformanceSync(
        runtime: DisplayRuntime,
        captureRegistry: DisplayCaptureRegistry,
        preferences: CapturePerformancePreferences
    ) {
        preferences.onModeChanged = { [weak runtime, weak preferences] mode in
            Task { @MainActor in
                await captureRegistry.updatePerformanceMode(mode)
                guard preferences?.mode == mode else { return }
                await runtime?.updateConsumerPowerProfile(mode.runtimeCapturePowerProfile)
            }
        }
    }

    static func makeVirtualDisplayRuntimeExecutors(
        runtime: DisplayRuntime
    ) -> VirtualDisplayRuntimeExecutors {
        VirtualDisplayRuntimeExecutors(
            rebuild: { configID, source in
                try await performRuntimeOperation(operation: .rebuild) {
                    let result = try await runtime.rebuildVirtualDisplay(
                        configID: configID,
                        source: DisplayRuntimeTransactionSource(source)
                    )
                    try requireSuccessfulRuntimeResult(
                        status: result.status,
                        commandSucceeded: result.virtualDisplayCommandSucceeded,
                        operation: .rebuild
                    )
                }
            },
            setDesiredEnabled: { configID, enabled, source in
                let operation = DisplayRuntimeExecutorError.Operation.setDesiredEnabled(enabled)
                try await performRuntimeOperation(operation: operation) {
                    let result = try await runtime.setVirtualDisplayDesiredEnabled(
                        configID: configID,
                        enabled: enabled,
                        source: DisplayRuntimeTransactionSource(source)
                    )
                    try requireSuccessfulRuntimeResult(
                        status: result.status,
                        commandSucceeded: result.virtualDisplayCommandSucceeded,
                        operation: operation
                    )
                }
            },
            editAndRebuild: { updatedConfig, expectedConfigFingerprint, source in
                let operation = DisplayRuntimeExecutorError.Operation.editAndRebuild
                return try await performRuntimeOperation(operation: operation) {
                    let runtimeSource = DisplayRuntimeTransactionSource(source)
                    let runtimeHandle = try await runtime.saveVirtualDisplayConfigAndRebuild(
                        request: DisplayRuntimeVirtualDisplayEditRebuildRequest(
                            editedConfig: DisplayRuntimeVirtualDisplayConfigEditDTO(adapterConfig: updatedConfig),
                            expectedConfigFingerprint: expectedConfigFingerprint,
                            source: runtimeSource
                        ),
                        source: runtimeSource
                    )
                    return VirtualDisplayEditRebuildOperation(
                        saveTask: Task { @MainActor in
                            try await performRuntimeOperation(operation: operation) {
                                _ = try await runtimeHandle.waitForSaveGate()
                            }
                        },
                        completionTask: Task { @MainActor in
                            try await performRuntimeOperation(operation: operation) {
                                let result = try await runtimeHandle.waitForTerminalResult()
                                try requireSuccessfulRuntimeResult(
                                    status: result.status,
                                    commandSucceeded: result.virtualDisplayCommandSucceeded,
                                    operation: operation
                                )
                            }
                        }
                    )
                }
            },
            create: { request in
                try await performRuntimeOperation(operation: .create) {
                    let source = DisplayRuntimeTransactionSource.createVirtualDisplaySheet
                    let result = try await runtime.createVirtualDisplay(
                        request: DisplayRuntimeVirtualDisplayCreateRequest(request: request, source: source),
                        source: source
                    )
                    try requireSuccessfulRuntimeResult(
                        status: result.status,
                        commandSucceeded: result.runtimeCreationOutcome == .succeeded,
                        operation: .create
                    )
                    return try requireCreatedConfigID(result.createdConfigID)
                }
            },
            delete: { configID in
                try await performRuntimeOperation(operation: .delete) {
                    let result = try await runtime.deleteVirtualDisplay(
                        configID: configID,
                        source: .deleteVirtualDisplayConfirmation
                    )
                    try requireSuccessfulRuntimeResult(
                        status: result.status,
                        commandSucceeded: result.virtualDisplayCommandOutcome == .succeeded,
                        operation: .delete
                    )
                }
            }
        )
    }

    static func performRuntimeOperation<Result>(
        operation: DisplayRuntimeExecutorError.Operation,
        _ body: () async throws -> Result
    ) async throws -> Result {
        do {
            return try await body()
        } catch let error as DisplayRuntimeExecutorError {
            throw error
        } catch is CancellationError {
            throw DisplayRuntimeExecutorError(operation: operation, reason: "cancelled")
        } catch {
            throw DisplayRuntimeExecutorError(operation: operation, reason: "runtime_operation_failed")
        }
    }

    static func requireSuccessfulRuntimeResult(
        status: DisplayRuntimeTransactionStatus,
        commandSucceeded: Bool,
        operation: DisplayRuntimeExecutorError.Operation
    ) throws {
        guard commandSucceeded,
              status == .completed || status == .completedWithRecoveryFailures else {
            throw DisplayRuntimeExecutorError(
                operation: operation,
                reason: commandSucceeded ? status.rawValue : "virtual_display_command_failed"
            )
        }
    }

    static func requireCreatedConfigID(_ configID: UUID?) throws -> UUID {
        guard let configID else {
            throw DisplayRuntimeExecutorError(
                operation: .create,
                reason: "missing_created_config_id"
            )
        }
        return configID
    }
}
