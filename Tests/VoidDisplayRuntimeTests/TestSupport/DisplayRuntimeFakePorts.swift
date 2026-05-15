@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation

@MainActor
final class FakeCatalogProvider: DisplayRuntimeCatalogProviding {
    var snapshot: DisplayRuntimeCatalogSnapshot

    init(snapshot: DisplayRuntimeCatalogSnapshot = .empty) {
        self.snapshot = snapshot
    }

    func makeCatalogSnapshot() -> DisplayRuntimeCatalogSnapshot {
        snapshot
    }

    func setSnapshot(_ snapshot: DisplayRuntimeCatalogSnapshot) {
        self.snapshot = snapshot
    }
}

struct DisplayRuntimeCatalogSubmitCall: Equatable {
    let intent: DisplayRuntimeCatalogRefreshIntent
    let ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?
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
final class FakeCatalogCommander: DisplayRuntimeCatalogProviding, DisplayRuntimeCatalogCommanding {
    private let recorder: RuntimeOperationRecorder?
    private let onRefresh: (() -> Void)?
    private var refreshResults: [DisplayRuntimeCatalogRefreshResult]
    private var submitContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var submitCallWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    var snapshot: DisplayRuntimeCatalogSnapshot
    var requestPermissionResult = true
    var refreshPermissionResults: [Bool]
    var visibleDisplays: [DisplayRuntimeVisibleDisplay]
    var shouldGateSubmitRefresh = false
    private(set) var requestPermissionCallCount = 0
    private(set) var refreshPermissionCallCount = 0
    private(set) var submitCalls: [DisplayRuntimeCatalogSubmitCall] = []
    private(set) var clearLoadErrorMessages: [String?] = []
    private(set) var cancelledOwnerScopes: [DisplayRuntimeCatalogRefreshOwnerScope?] = []

    init(
        snapshot: DisplayRuntimeCatalogSnapshot = .empty,
        recorder: RuntimeOperationRecorder? = nil,
        refreshPermissionResults: [Bool] = [true],
        refreshResults: [DisplayRuntimeCatalogRefreshResult] = [.reusedSnapshot],
        visibleDisplays: [DisplayRuntimeVisibleDisplay] = [],
        onRefresh: (() -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.recorder = recorder
        self.refreshPermissionResults = refreshPermissionResults
        self.refreshResults = refreshResults
        self.visibleDisplays = visibleDisplays
        self.onRefresh = onRefresh
    }

    func makeCatalogSnapshot() -> DisplayRuntimeCatalogSnapshot {
        snapshot
    }

    func requestPermission() -> Bool {
        requestPermissionCallCount += 1
        return requestPermissionResult
    }

    func refreshPermission() -> Bool {
        refreshPermissionCallCount += 1
        guard !refreshPermissionResults.isEmpty else { return true }
        return refreshPermissionResults.removeFirst()
    }

    func submitRefresh(
        intent: DisplayRuntimeCatalogRefreshIntent,
        ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?
    ) async -> DisplayRuntimeCatalogRefreshResult {
        submitCalls.append(.init(intent: intent, ownerScope: ownerScope))
        recorder?.append("refresh:\(intent.rawValue)")
        resumeSubmitCallWaiters()
        onRefresh?()
        let callIndex = submitCalls.count
        if shouldGateSubmitRefresh {
            await withCheckedContinuation { continuation in
                submitContinuations[callIndex] = continuation
            }
        }
        if refreshResults.count > 1 {
            return refreshResults.removeFirst()
        }
        return refreshResults.first ?? .reusedSnapshot
    }

    func clearSnapshotForDeniedPermission(loadErrorMessage: String?) async {
        clearLoadErrorMessages.append(loadErrorMessage)
    }

    func cancelRefresh(ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?) async {
        cancelledOwnerScopes.append(ownerScope)
    }

    func currentVisibleDisplays() -> [DisplayRuntimeVisibleDisplay] {
        visibleDisplays
    }

    func releaseSubmitRefresh(call: Int) {
        submitContinuations.removeValue(forKey: call)?.resume()
    }

    func waitForSubmitCalls(_ count: Int) async {
        guard submitCalls.count < count else { return }
        await withCheckedContinuation { continuation in
            submitCallWaiters[count, default: []].append(continuation)
        }
    }

    private func resumeSubmitCallWaiters() {
        let readyCounts = submitCallWaiters.keys.filter { submitCalls.count >= $0 }
        for count in readyCounts {
            let waiters = submitCallWaiters.removeValue(forKey: count) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}

@MainActor
final class FakeSharingCommander: DisplayRuntimeSharingProviding, DisplayRuntimeSharingCommanding {
    private let recorder: RuntimeOperationRecorder?
    private let restoreResult: DisplayRuntimeSharingRestoreCommandResult
    var snapshot: DisplayRuntimeSharingSnapshot
    private(set) var registeredDisplays: [[DisplayRuntimeShareableDisplayRegistration]] = []
    private(set) var stoppedDisplayIDs: [DisplayRuntimeDisplayID] = []
    private(set) var restoredDisplayIDs: [DisplayRuntimeDisplayID] = []

    init(
        snapshot: DisplayRuntimeSharingSnapshot = .empty,
        recorder: RuntimeOperationRecorder? = nil,
        restoreResult: DisplayRuntimeSharingRestoreCommandResult = .restored
    ) {
        self.snapshot = snapshot
        self.recorder = recorder
        self.restoreResult = restoreResult
    }

    func makeSharingSnapshot() -> DisplayRuntimeSharingSnapshot {
        snapshot
    }

    func registerShareableDisplays(_ displays: [DisplayRuntimeShareableDisplayRegistration]) {
        registeredDisplays.append(displays)
        let displayIDs = displays.map(\.displayID).sorted()
        recorder?.append("registerShareable:\(displayIDs.map(String.init).joined(separator: ","))")
    }

    func stopSharing(displayID: DisplayRuntimeDisplayID) {
        stoppedDisplayIDs.append(displayID)
        recorder?.append("stopSharing:\(displayID)")
    }

    func restoreSharing(displayID: DisplayRuntimeDisplayID) async -> DisplayRuntimeSharingRestoreCommandResult {
        restoredDisplayIDs.append(displayID)
        recorder?.append("restoreSharing:\(displayID)")
        return restoreResult
    }
}

@MainActor
final class FakeCaptureCommander: DisplayRuntimeCaptureProviding, DisplayRuntimeCaptureCommanding {
    private let recorder: RuntimeOperationRecorder?
    var snapshot: DisplayRuntimeCaptureSnapshot
    private(set) var removedDisplayIDs: [DisplayRuntimeDisplayID] = []

    init(
        snapshot: DisplayRuntimeCaptureSnapshot = .empty,
        recorder: RuntimeOperationRecorder? = nil
    ) {
        self.snapshot = snapshot
        self.recorder = recorder
    }

    func makeCaptureSnapshot() -> DisplayRuntimeCaptureSnapshot {
        snapshot
    }

    func removeMonitoringSessions(displayID: DisplayRuntimeDisplayID) {
        removedDisplayIDs.append(displayID)
        recorder?.append("removeMonitoring:\(displayID)")
    }
}

@MainActor
final class FakeObservabilityRecorder: DisplayRuntimeObservabilityRecording {
    private(set) var events: [DisplayRuntimeObservabilityEvent] = []
    private(set) var refreshReasons: [DisplayRuntimeObservabilityRefreshReason] = []

    func record(_ event: DisplayRuntimeObservabilityEvent) async {
        events.append(event)
    }

    func refreshSnapshot(reason: DisplayRuntimeObservabilityRefreshReason) async {
        refreshReasons.append(reason)
    }
}

@MainActor
final class FakeCaptureIntentCommander: DisplayRuntimeCaptureIntentCommanding {
    typealias ResultProvider = @MainActor (DisplayRuntimeCaptureIntent) -> DisplayRuntimeCaptureIntentApplyResult

    private(set) var intents: [DisplayRuntimeCaptureIntent] = []
    private(set) var returnedResults: [DisplayRuntimeCaptureIntentApplyResult] = []

    private let resultProvider: ResultProvider

    init(
        resultProvider: @escaping ResultProvider = {
            .applied(revision: $0.revision)
        }
    ) {
        self.resultProvider = resultProvider
    }

    func applyCaptureIntent(_ intent: DisplayRuntimeCaptureIntent) -> DisplayRuntimeCaptureIntentApplyResult {
        intents.append(intent)
        let result = resultProvider(intent)
        returnedResults.append(result)
        return result
    }
}

@MainActor
final class FakeVirtualDisplayCommander: DisplayRuntimeVirtualDisplayCommanding, DisplayRuntimeStartupRestoreCommanding {
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
    var startupConfigLoadCallCount = 0
    var startupRestoreCallCount = 0
    var startupRestoreRequests: [DisplayRuntimeStartupRestoreCommandRequest] = []
    var enablePreflight: DisplayRuntimeVirtualDisplayEnablePreflight?
    var setDesiredEnabledError: Error?
    var saveConfigForRebuildError: Error?
    var restoreConfigAfterFailedEditError: Error?
    var saveConfigForRebuildResult: DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult?
    var restoreConfigAfterFailedEditResult: DisplayRuntimeVirtualDisplayPersistenceCommandResult?
    var createResult: DisplayRuntimeVirtualDisplayCreateCommandResult?
    var deleteResult: DisplayRuntimeVirtualDisplayDeleteCommandResult?
    var startupConfigLoadResult: DisplayRuntimeStartupRestoreConfigLoadResult = .succeeded(configs: [])
    var startupRestoreResults: [DisplayRuntimeStartupRestoreCommandResult] = []
    var enableError: Error?
    var disableError: Error?
    var createError: Error?
    var deleteError: Error?
    var startupRestoreError: Error?
    var onSetDesiredEnabled: ((UUID, Bool) -> Void)?
    var onSaveConfigForRebuild: ((DisplayRuntimeVirtualDisplayEditRebuildRequest) -> Void)?
    var onRestoreConfigAfterFailedEdit: ((DisplayRuntimeVirtualDisplayConfigEditDTO) -> Void)?
    var onEnable: ((UUID) -> Void)?
    var onDisable: ((UUID) -> Void)?
    var onCreate: ((DisplayRuntimeVirtualDisplayCreateRequest) -> Void)?
    var onDelete: ((DisplayRuntimeVirtualDisplayDeleteCommandRequest) -> Void)?
    var onStartupRestore: ((DisplayRuntimeStartupRestoreCommandRequest) -> Void)?
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

    func loadPersistedVirtualDisplayConfigsForStartupRestore()
        async -> DisplayRuntimeStartupRestoreConfigLoadResult
    {
        startupConfigLoadCallCount += 1
        recorder?.append("loadStartupConfigs")
        return startupConfigLoadResult
    }

    func restoreVirtualDisplayForStartup(
        request: DisplayRuntimeStartupRestoreCommandRequest
    ) async throws -> DisplayRuntimeStartupRestoreCommandResult {
        startupRestoreCallCount += 1
        startupRestoreRequests.append(request)
        recorder?.append("startupRestore:\(request.configID.uuidString)")
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let startupRestoreError {
            throw startupRestoreError
        }
        onStartupRestore?(request)
        if !startupRestoreResults.isEmpty {
            var result = startupRestoreResults.removeFirst()
            if result.transactionID != request.transactionID {
                result = startupRestoreCommandResult(
                    transactionID: request.transactionID,
                    configID: result.configID,
                    preDisplayID: result.preDisplayID,
                    postDisplayID: result.postDisplayID,
                    restoreOutcome: result.restoreOutcome,
                    didProduceVerifiableSideEffect: result.didProduceVerifiableSideEffect,
                    failureReason: result.failureReason,
                    compensationOutcome: result.compensationOutcome,
                    compensationFailureReason: result.compensationFailureReason,
                    runningConfigIDsAfterCommand: result.runningConfigIDsAfterCommand,
                    managedDisplaysAfterCommand: result.managedDisplaysAfterCommand
                )
            }
            return result
        }
        return startupRestoreCommandResult(
            transactionID: request.transactionID,
            configID: request.configID,
            postDisplayID: 9001,
            runningConfigIDsAfterCommand: [request.configID],
            managedDisplaysAfterCommand: [
                .init(
                    configID: request.configID,
                    serialNumber: request.configEvidence.serialNumber,
                    displayID: 9001,
                    isLiveRuntime: true
                )
            ]
        )
    }
}
