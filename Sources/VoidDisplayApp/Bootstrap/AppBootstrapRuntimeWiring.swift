import VoidDisplayCapture
import VoidDisplayRuntime
import VoidDisplayVirtualDisplay

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
            let result = try await runtime.rebuildVirtualDisplay(
                configID: configID,
                source: DisplayRuntimeTransactionSource(source)
            )
            guard result.status != .failed && result.status != .cancelled else {
                throw DisplayRuntimeRebuildExecutorError(transactionStatus: result.status.rawValue)
            }
            },
            setDesiredEnabled: { configID, enabled, source in
            let result = try await runtime.setVirtualDisplayDesiredEnabled(
                configID: configID,
                enabled: enabled,
                source: DisplayRuntimeTransactionSource(source)
            )
            guard result.status != .failed && result.status != .cancelled else {
                throw DisplayRuntimeRebuildExecutorError(transactionStatus: result.status.rawValue)
            }
            },
            editAndRebuild: { updatedConfig, expectedConfigFingerprint, source in
            let runtimeSource = DisplayRuntimeTransactionSource(source)
            let runtimeHandle = try await runtime.saveVirtualDisplayConfigAndRebuild(
                request: DisplayRuntimeVirtualDisplayEditRebuildRequest(
                    editedConfig: DisplayRuntimeVirtualDisplayConfigEditDTO(adapterConfig: updatedConfig),
                    expectedConfigFingerprint: expectedConfigFingerprint,
                    source: runtimeSource
                ),
                source: runtimeSource
            )
            return VirtualDisplayEditRebuildTransactionHandle(
                transactionID: runtimeHandle.transactionID.rawValue,
                saveGateTask: Task { @MainActor in
                    let saveGate = try await runtimeHandle.waitForSaveGate()
                    return VirtualDisplayEditRebuildSaveGateResult(
                        transactionID: saveGate.transactionID.rawValue,
                        configID: saveGate.configID
                    )
                },
                terminalResultTask: Task { @MainActor in
                    let result = try await runtimeHandle.waitForTerminalResult()
                    return VirtualDisplayEditRebuildTransactionResult(
                        transactionID: result.transactionID.rawValue,
                        status: VirtualDisplayTransactionStatus(result.status),
                        virtualDisplayCommandSucceeded: result.virtualDisplayCommandSucceeded
                    )
                }
            )
            },
            create: { request in
            let source = DisplayRuntimeTransactionSource.createVirtualDisplaySheet
            let result = try await runtime.createVirtualDisplay(
                request: DisplayRuntimeVirtualDisplayCreateRequest(request: request, source: source),
                source: source
            )
            return VirtualDisplayCreateTransactionResult(
                transactionID: result.transactionID.rawValue,
                status: VirtualDisplayTransactionStatus(result.status),
                createdConfigID: result.createdConfigID,
                virtualDisplayCommandSucceeded: result.runtimeCreationOutcome == .succeeded
            )
            },
            delete: { configID in
            let result = try await runtime.deleteVirtualDisplay(
                configID: configID,
                source: .deleteVirtualDisplayConfirmation
            )
            return VirtualDisplayDeleteTransactionResult(
                transactionID: result.transactionID.rawValue,
                status: VirtualDisplayTransactionStatus(result.status),
                configID: result.configID,
                virtualDisplayCommandSucceeded: result.virtualDisplayCommandOutcome == .succeeded
            )
            }
        )
    }
}
