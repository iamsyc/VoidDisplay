@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation

@MainActor
final class FakeCatalogProvider: DisplayRuntimeCatalogProviding {
    private var snapshot: DisplayRuntimeCatalogSnapshot

    init(snapshot: DisplayRuntimeCatalogSnapshot) {
        self.snapshot = snapshot
    }

    func makeCatalogSnapshot() -> DisplayRuntimeCatalogSnapshot {
        snapshot
    }

    func setSnapshot(_ snapshot: DisplayRuntimeCatalogSnapshot) {
        self.snapshot = snapshot
    }
}

@MainActor
final class FakeCaptureProvider: DisplayRuntimeCaptureProviding {
    let snapshot: DisplayRuntimeCaptureSnapshot

    init(snapshot: DisplayRuntimeCaptureSnapshot) {
        self.snapshot = snapshot
    }

    func makeCaptureSnapshot() -> DisplayRuntimeCaptureSnapshot {
        snapshot
    }
}

@MainActor
final class FakeSharingProvider: DisplayRuntimeSharingProviding {
    private var snapshot: DisplayRuntimeSharingSnapshot

    init(snapshot: DisplayRuntimeSharingSnapshot) {
        self.snapshot = snapshot
    }

    func makeSharingSnapshot() -> DisplayRuntimeSharingSnapshot {
        snapshot
    }

    func setSnapshot(_ snapshot: DisplayRuntimeSharingSnapshot) {
        self.snapshot = snapshot
    }
}

@MainActor
final class FakeVirtualDisplayProvider: DisplayRuntimeVirtualDisplayProviding {
    private var snapshot: DisplayRuntimeVirtualDisplaySnapshot

    init(snapshot: DisplayRuntimeVirtualDisplaySnapshot) {
        self.snapshot = snapshot
    }

    func makeVirtualDisplaySnapshot() -> DisplayRuntimeVirtualDisplaySnapshot {
        snapshot
    }

    func setSnapshot(_ snapshot: DisplayRuntimeVirtualDisplaySnapshot) {
        self.snapshot = snapshot
    }
}

@MainActor
final class FakeCatalogCommander: DisplayRuntimeCatalogCommanding {
    private let recorder: RuntimeOperationRecorder?
    private let visibleDisplays: [DisplayRuntimeVisibleDisplay]
    private let onRefresh: (() -> Void)?
    private var refreshResults: [DisplayRuntimeCatalogRefreshResult]

    init(
        recorder: RuntimeOperationRecorder? = nil,
        refreshResults: [DisplayRuntimeCatalogRefreshResult] = [.reusedSnapshot],
        visibleDisplays: [DisplayRuntimeVisibleDisplay] = [],
        onRefresh: (() -> Void)? = nil
    ) {
        self.recorder = recorder
        self.refreshResults = refreshResults
        self.visibleDisplays = visibleDisplays
        self.onRefresh = onRefresh
    }

    func requestPermission() -> Bool {
        true
    }

    func refreshPermission() -> Bool {
        true
    }

    func submitRefresh(
        intent: DisplayRuntimeCatalogRefreshIntent,
        ownerScope _: DisplayRuntimeCatalogRefreshOwnerScope?
    ) async -> DisplayRuntimeCatalogRefreshResult {
        recorder?.append("refresh:\(intent.rawValue)")
        onRefresh?()
        if refreshResults.count > 1 {
            return refreshResults.removeFirst()
        }
        return refreshResults.first ?? .reusedSnapshot
    }

    func clearSnapshotForDeniedPermission(loadErrorMessage _: String?) async {}

    func cancelRefresh(ownerScope _: DisplayRuntimeCatalogRefreshOwnerScope?) async {}

    func currentVisibleDisplays() -> [DisplayRuntimeVisibleDisplay] {
        visibleDisplays
    }
}

@MainActor
final class FakeSharingCommander: DisplayRuntimeSharingCommanding {
    private let recorder: RuntimeOperationRecorder?
    private let restoreResult: DisplayRuntimeSharingRestoreCommandResult
    private(set) var restoredDisplayIDs: [DisplayRuntimeDisplayID] = []

    init(
        recorder: RuntimeOperationRecorder? = nil,
        restoreResult: DisplayRuntimeSharingRestoreCommandResult = .restored
    ) {
        self.recorder = recorder
        self.restoreResult = restoreResult
    }

    func registerShareableDisplays(_ displays: [DisplayRuntimeShareableDisplayRegistration]) {
        let displayIDs = displays.map(\.displayID).sorted()
        recorder?.append("registerShareable:\(displayIDs.map(String.init).joined(separator: ","))")
    }

    func stopSharing(displayID: DisplayRuntimeDisplayID) {
        recorder?.append("stopSharing:\(displayID)")
    }

    func restoreSharing(displayID: DisplayRuntimeDisplayID) async -> DisplayRuntimeSharingRestoreCommandResult {
        restoredDisplayIDs.append(displayID)
        recorder?.append("restoreSharing:\(displayID)")
        return restoreResult
    }
}

@MainActor
final class FakeCaptureCommander: DisplayRuntimeCaptureCommanding {
    private let recorder: RuntimeOperationRecorder?

    init(recorder: RuntimeOperationRecorder? = nil) {
        self.recorder = recorder
    }

    func removeMonitoringSessions(displayID: DisplayRuntimeDisplayID) {
        recorder?.append("removeMonitoring:\(displayID)")
    }
}

@MainActor
final class FakeVirtualDisplayCommander: DisplayRuntimeVirtualDisplayCommanding {
    private let recorder: RuntimeOperationRecorder?
    private let delayNanoseconds: UInt64
    var rebuildCallCount = 0
    var rebuildConfigIDs: [UUID] = []
    var preflightCallCount = 0
    var setDesiredEnabledCallCount = 0
    var setDesiredEnabledRequests: [(UUID, Bool)] = []
    var saveConfigForRebuildCallCount = 0
    var saveConfigForRebuildRequests: [DisplayRuntimeVirtualDisplayEditRebuildRequest] = []
    var restoreConfigAfterFailedEditCallCount = 0
    var restoredConfigsAfterFailedEdit: [DisplayRuntimeVirtualDisplayConfigEditDTO] = []
    var enableCallCount = 0
    var enableConfigIDs: [UUID] = []
    var disableCallCount = 0
    var disableConfigIDs: [UUID] = []
    var createCallCount = 0
    var createRequests: [DisplayRuntimeVirtualDisplayCreateRequest] = []
    var deleteCallCount = 0
    var deleteRequests: [DisplayRuntimeVirtualDisplayDeleteCommandRequest] = []
    var enablePreflight: DisplayRuntimeVirtualDisplayEnablePreflight?
    var setDesiredEnabledError: Error?
    var saveConfigForRebuildError: Error?
    var restoreConfigAfterFailedEditError: Error?
    var saveConfigForRebuildResult: DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult?
    var restoreConfigAfterFailedEditResult: DisplayRuntimeVirtualDisplayPersistenceCommandResult?
    var createResult: DisplayRuntimeVirtualDisplayCreateCommandResult?
    var deleteResult: DisplayRuntimeVirtualDisplayDeleteCommandResult?
    var enableError: Error?
    var disableError: Error?
    var createError: Error?
    var deleteError: Error?
    var onSetDesiredEnabled: ((UUID, Bool) -> Void)?
    var onSaveConfigForRebuild: ((DisplayRuntimeVirtualDisplayEditRebuildRequest) -> Void)?
    var onRestoreConfigAfterFailedEdit: ((DisplayRuntimeVirtualDisplayConfigEditDTO) -> Void)?
    var onEnable: ((UUID) -> Void)?
    var onDisable: ((UUID) -> Void)?
    var onCreate: ((DisplayRuntimeVirtualDisplayCreateRequest) -> Void)?
    var onDelete: ((DisplayRuntimeVirtualDisplayDeleteCommandRequest) -> Void)?
    var error: Error?
    var scriptedRebuildErrors: [Error?] = []

    init(
        recorder: RuntimeOperationRecorder? = nil,
        delayNanoseconds: UInt64 = 0
    ) {
        self.recorder = recorder
        self.delayNanoseconds = delayNanoseconds
    }

    func rebuildVirtualDisplay(configID: UUID) async throws -> DisplayRuntimeVirtualDisplayRebuildCommandResult {
        rebuildCallCount += 1
        rebuildConfigIDs.append(configID)
        recorder?.append("rebuild:\(configID.uuidString)")
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if !scriptedRebuildErrors.isEmpty {
            if let scriptedError = scriptedRebuildErrors.removeFirst() {
                throw scriptedError
            }
        } else if let error {
            throw error
        }
        return rebuildCommandResult(configID: configID)
    }

    func preflightEnableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayEnablePreflight {
        preflightCallCount += 1
        recorder?.append("preflightEnable:\(request.configID.uuidString)")
        return enablePreflight ?? .init(
            configID: request.configID,
            targetPreDisplayID: request.targetPreDisplayID,
            mayPerformFleetRebuild: false,
            requiresFleetQuiesce: false,
            scopeEscalationReason: nil
        )
    }

    func setVirtualDisplayDesiredEnabled(
        request: DisplayRuntimeVirtualDisplayDesiredEnabledCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayDesiredEnabledCommandResult {
        setDesiredEnabledCallCount += 1
        setDesiredEnabledRequests.append((request.configID, request.enabled))
        recorder?.append("setDesiredEnabled:\(request.configID.uuidString):\(request.enabled)")
        if let setDesiredEnabledError {
            throw setDesiredEnabledError
        }
        onSetDesiredEnabled?(request.configID, request.enabled)
        return .init(
            configID: request.configID,
            desiredEnabled: request.enabled,
            persistenceOutcome: .saved
        )
    }

    func saveConfigForRebuild(
        request: DisplayRuntimeVirtualDisplayEditRebuildRequest
    ) async throws -> DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult {
        saveConfigForRebuildCallCount += 1
        saveConfigForRebuildRequests.append(request)
        recorder?.append("saveConfigForRebuild:\(request.editedConfig.id.uuidString)")
        if let saveConfigForRebuildError {
            throw saveConfigForRebuildError
        }
        onSaveConfigForRebuild?(request)
        if let saveConfigForRebuildResult {
            return saveConfigForRebuildResult
        }
        return editRebuildSaveCommandResult(previousConfigForCompensation: request.editedConfig)
    }

    func restoreConfigAfterFailedEdit(
        request: DisplayRuntimeVirtualDisplayEditRebuildRestoreCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayPersistenceCommandResult {
        restoreConfigAfterFailedEditCallCount += 1
        restoredConfigsAfterFailedEdit.append(request.previousConfigForCompensation)
        recorder?.append("restoreConfigAfterFailedEdit:\(request.previousConfigForCompensation.id.uuidString)")
        if let restoreConfigAfterFailedEditError {
            throw restoreConfigAfterFailedEditError
        }
        onRestoreConfigAfterFailedEdit?(request.previousConfigForCompensation)
        return restoreConfigAfterFailedEditResult ?? persistenceCommandResult(
            configID: request.previousConfigForCompensation.id,
            persistenceOutcome: .rolledBack
        )
    }

    func enableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayLifecycleCommandResult {
        enableCallCount += 1
        enableConfigIDs.append(request.configID)
        recorder?.append("enable:\(request.configID.uuidString)")
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let enableError {
            throw enableError
        }
        onEnable?(request.configID)
        return lifecycleCommandResult(
            configID: request.configID,
            desiredEnabled: true,
            preDisplayID: request.targetPreDisplayID,
            postDisplayID: request.targetPreDisplayID,
            runningConfigIDsAfterCommand: [request.configID],
            mayPerformFleetRebuild: enablePreflight?.mayPerformFleetRebuild,
            requiresFleetQuiesce: enablePreflight?.requiresFleetQuiesce
        )
    }

    func disableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayLifecycleCommandResult {
        disableCallCount += 1
        disableConfigIDs.append(request.configID)
        recorder?.append("disable:\(request.configID.uuidString)")
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let disableError {
            throw disableError
        }
        onDisable?(request.configID)
        return lifecycleCommandResult(
            configID: request.configID,
            desiredEnabled: false,
            preDisplayID: request.targetPreDisplayID,
            postDisplayID: nil,
            runningConfigIDsAfterCommand: []
        )
    }

    func createVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayCreateRequest
    ) async throws -> DisplayRuntimeVirtualDisplayCreateCommandResult {
        createCallCount += 1
        createRequests.append(request)
        recorder?.append("create:\(request.serialNumber)")
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let createError {
            throw createError
        }
        onCreate?(request)
        if let createResult {
            return createResult
        }
        let createdConfigID = UUID()
        return createCommandResult(
            transactionID: request.transactionID,
            createdConfigID: createdConfigID,
            serialNumber: request.serialNumber,
            postDisplayID: 9001,
            physicalWidthMillimeters: request.physicalWidthMillimeters,
            physicalHeightMillimeters: request.physicalHeightMillimeters,
            modeCount: request.modes.count,
            maximumPixelWidth: request.maximumPixelWidth,
            maximumPixelHeight: request.maximumPixelHeight
        )
    }

    func deleteVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayDeleteCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayDeleteCommandResult {
        deleteCallCount += 1
        deleteRequests.append(request)
        recorder?.append("delete:\(request.configID.uuidString)")
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let deleteError {
            throw deleteError
        }
        onDelete?(request)
        return deleteResult ?? deleteCommandResult(
            transactionID: request.transactionID,
            configID: request.configID,
            targetWasRunning: request.targetWasRunning,
            preDisplayID: request.targetPreDisplayID,
            postDisplayID: nil
        )
    }
}
