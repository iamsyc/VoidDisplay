import Foundation

@MainActor
package protocol DisplayRuntimeCatalogProviding {
    func makeCatalogSnapshot() -> DisplayRuntimeCatalogSnapshot
}

@MainActor
package protocol DisplayRuntimeCaptureProviding {
    func makeCaptureSnapshot() -> DisplayRuntimeCaptureSnapshot
}

@MainActor
package protocol DisplayRuntimeSharingProviding {
    func makeSharingSnapshot() -> DisplayRuntimeSharingSnapshot
}

@MainActor
package protocol DisplayRuntimeVirtualDisplayProviding {
    func makeVirtualDisplaySnapshot() -> DisplayRuntimeVirtualDisplaySnapshot
}

@MainActor
package protocol DisplayRuntimeVirtualDisplayCommanding {
    func rebuildVirtualDisplay(configID: UUID) async throws -> DisplayRuntimeVirtualDisplayRebuildCommandResult
    func preflightEnableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayEnablePreflight
    func setVirtualDisplayDesiredEnabled(
        request: DisplayRuntimeVirtualDisplayDesiredEnabledCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayDesiredEnabledCommandResult
    func saveConfigForRebuild(
        request: DisplayRuntimeVirtualDisplayEditRebuildRequest
    ) async throws -> DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult
    func restoreConfigAfterFailedEdit(
        request: DisplayRuntimeVirtualDisplayEditRebuildRestoreCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayPersistenceCommandResult
    func enableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayLifecycleCommandResult
    func disableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayLifecycleCommandResult
    func createVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayCreateRequest
    ) async throws -> DisplayRuntimeVirtualDisplayCreateCommandResult
    func deleteVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayDeleteCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayDeleteCommandResult
}

@MainActor
package protocol DisplayRuntimeStartupRestoreCommanding {
    func loadPersistedVirtualDisplayConfigsForStartupRestore()
        async -> DisplayRuntimeStartupRestoreConfigLoadResult
    func restoreVirtualDisplayForStartup(
        request: DisplayRuntimeStartupRestoreCommandRequest
    ) async throws -> DisplayRuntimeStartupRestoreCommandResult
}

@MainActor
package protocol DisplayRuntimeCatalogCommanding {
    func requestPermission() -> Bool
    func refreshPermission() -> Bool
    func submitRefresh(intent: DisplayRuntimeCatalogRefreshIntent) async -> DisplayRuntimeCatalogRefreshOutcome
    func clearSnapshotForDeniedPermission(
        loadErrorMessage: String?
    ) async -> DisplayRuntimeCatalogRefreshOutcome
}

@MainActor
package protocol DisplayRuntimeSharingCommanding {
    func registerShareableDisplays(_ displays: [DisplayRuntimeShareableDisplayRegistration])
}

@MainActor
package protocol DisplayRuntimeCaptureIntentCommanding {
    func applyPreviewCaptureIntent(_ intent: DisplayRuntimeCaptureIntent) async -> DisplayRuntimeCaptureIntentApplyResult
    func applyLANWebViewCaptureIntent(_ intent: DisplayRuntimeCaptureIntent) async -> DisplayRuntimeCaptureIntentApplyResult
}

@MainActor
package protocol DisplayRuntimeObservabilityRecording {
    func record(_ event: DisplayRuntimeObservabilityEvent) async
    func refreshSnapshot(reason: DisplayRuntimeObservabilityRefreshReason) async
}
