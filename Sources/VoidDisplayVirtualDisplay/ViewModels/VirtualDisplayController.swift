import VoidDisplayObservability
import VoidDisplayDesignSystem
import VoidDisplayFoundation
//
//  VirtualDisplayController.swift
//  VoidDisplay
//

import Foundation
import CoreGraphics
import Observation
import OSLog

package typealias VirtualDisplayRebuildExecutor = @MainActor (
    UUID,
    VirtualDisplayRebuildRequestSource
) async throws -> Void

package typealias VirtualDisplayDesiredEnabledExecutor = @MainActor (
    UUID,
    Bool,
    VirtualDisplayDesiredEnabledRequestSource
) async throws -> Void

package typealias VirtualDisplayEditRebuildExecutor = @MainActor (
    VirtualDisplayConfig,
    String,
    VirtualDisplayRebuildRequestSource
) async throws -> VirtualDisplayEditRebuildTransactionHandle

package typealias VirtualDisplayCreateExecutor = @MainActor (
    VirtualDisplayCreateRequest
) async throws -> VirtualDisplayCreateTransactionResult

package typealias VirtualDisplayDeleteExecutor = @MainActor (
    UUID
) async throws -> VirtualDisplayDeleteTransactionResult

package nonisolated enum VirtualDisplayRebuildRequestSource: Sendable {
    case rowRetry
    case editSaveAndRebuild
    case unknown
}

package nonisolated enum VirtualDisplayDesiredEnabledRequestSource: Sendable {
    case rowToggle
    case unknown
}

private struct VirtualDisplayRebuildExecutorUnavailableError: LocalizedError {
    var errorDescription: String? {
        String(localized: "Failed to rebuild virtual display.")
    }
}

private struct VirtualDisplayDesiredEnabledExecutorUnavailableError: Error {}

private struct VirtualDisplayEditRebuildExecutorUnavailableError: Error {}

private struct VirtualDisplayCreateExecutorUnavailableError: Error {}

private struct VirtualDisplayDeleteExecutorUnavailableError: Error {}

private struct VirtualDisplayEditRebuildPresentationError: LocalizedError {
    var errorDescription: String? { nil }
}

private struct VirtualDisplayRuntimeCommandPresentationError: LocalizedError {
    var errorDescription: String? { nil }
}

@MainActor
@Observable
package final class VirtualDisplayController {
    package var managedDisplays: [ManagedVirtualDisplayRuntimeSnapshot] { virtualDisplaySnapshot.managedDisplays }
    package var displayConfigs: [VirtualDisplayConfig] { virtualDisplaySnapshot.configs }
    package var runningConfigIds: Set<UUID> { virtualDisplaySnapshot.runningConfigIds }
    package var restoreFailures: [VirtualDisplayRestoreFailure] { virtualDisplaySnapshot.restoreFailures }
    package var persistenceAlert: UserFacingAlertState?
    package var runtimeDisplayIDByConfigId: [UUID: CGDirectDisplayID] { virtualDisplaySnapshot.runtimeDisplayIDByConfigId }
    package var rebuildingConfigIds: Set<UUID> { rebuildPresentationState.rebuildingConfigIds }
    package var rebuildFailureMessageByConfigId: [UUID: String] { rebuildPresentationState.rebuildFailureMessageByConfigId }
    package var recentlyAppliedConfigIds: Set<UUID> { rebuildPresentationState.recentlyAppliedConfigIds }
    package var configStorePresentation: VirtualDisplayConfigStorePresentation { virtualDisplaySnapshot.configStorePresentation }
    package private(set) var rebuildRequestCount = 0

    @ObservationIgnored private let virtualDisplayFacade: any VirtualDisplayFacade
    @ObservationIgnored private var rebuildTasksByConfigId: [UUID: [UUID: Task<Void, Never>]] = [:]
    @ObservationIgnored private var appliedBadgeClearTasksByConfigId: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var rebuildPresentationWaiterCountByConfigId: [UUID: Int] = [:]
    @ObservationIgnored private var rebuildExecutor: VirtualDisplayRebuildExecutor?
    @ObservationIgnored private var desiredEnabledExecutor: VirtualDisplayDesiredEnabledExecutor?
    @ObservationIgnored private var editRebuildExecutor: VirtualDisplayEditRebuildExecutor?
    @ObservationIgnored private var createExecutor: VirtualDisplayCreateExecutor?
    @ObservationIgnored private var deleteExecutor: VirtualDisplayDeleteExecutor?
    private var virtualDisplaySnapshot: VirtualDisplaySnapshot
    private var rebuildPresentationState = RebuildPresentationState()
    @ObservationIgnored private let appliedBadgeDisplayDuration: Duration
    @ObservationIgnored private weak var observability: ObservabilityCenter?

    package init(
        virtualDisplayFacade: any VirtualDisplayFacade,
        appliedBadgeDisplayDuration: Duration,
        observability: ObservabilityCenter? = nil
    ) {
        self.virtualDisplayFacade = virtualDisplayFacade
        self.virtualDisplaySnapshot = virtualDisplayFacade.snapshot
        self.appliedBadgeDisplayDuration = appliedBadgeDisplayDuration
        self.observability = observability
        requestSnapshotRefresh()
    }

    package func runtimeDisplayID(for configId: UUID) -> CGDirectDisplayID? {
        runtimeDisplayIDByConfigId[configId]
    }

    package func isManagedVirtualDisplay(displayID: CGDirectDisplayID) -> Bool {
        managedDisplays.contains(where: { $0.displayID == displayID })
    }

    package func virtualSerialForManagedDisplay(_ displayID: CGDirectDisplayID) -> UInt32? {
        managedDisplays.first(where: { $0.displayID == displayID })?.serialNum
    }

    package func isVirtualDisplayRunning(configId: UUID) -> Bool {
        runningConfigIds.contains(configId)
    }

    package func clearRestoreFailures() {
        mutateAndSync {
            virtualDisplayFacade.clearRestoreFailures()
        }
    }

    package func dismissPersistenceAlert() {
        persistenceAlert = nil
    }

    package func configureObservability(_ observability: ObservabilityCenter?) {
        self.observability = observability
        requestSnapshotRefresh()
    }

    package func configureRebuildExecutor(_ executor: VirtualDisplayRebuildExecutor?) {
        rebuildExecutor = executor
    }

    package func configureDesiredEnabledExecutor(_ executor: VirtualDisplayDesiredEnabledExecutor?) {
        desiredEnabledExecutor = executor
    }

    package func configureEditRebuildExecutor(_ executor: VirtualDisplayEditRebuildExecutor?) {
        editRebuildExecutor = executor
    }

    package func configureCreateExecutor(_ executor: VirtualDisplayCreateExecutor?) {
        createExecutor = executor
    }

    package func configureDeleteExecutor(_ executor: VirtualDisplayDeleteExecutor?) {
        deleteExecutor = executor
    }

    package func refreshVirtualDisplayState() {
        syncVirtualDisplayState()
    }

    package func startRebuildFromSavedConfig(
        configId: UUID,
        source: VirtualDisplayRebuildRequestSource = .unknown
    ) {
        rebuildRequestCount += 1

        incrementRebuildPresentationWaiter(configId: configId)
        appliedBadgeClearTasksByConfigId[configId]?.cancel()
        appliedBadgeClearTasksByConfigId[configId] = nil
        Task {
            await recordEvent(
                severity: .info,
                operation: "Rebuild virtual display",
                message: "Started rebuild request.",
                metadata: ["configID": configId.uuidString],
                deduplicationKey: "virtualDisplay.rebuild.\(configId.uuidString)"
            )
        }

        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.decrementRebuildPresentationWaiter(configId: configId)
                self.rebuildTasksByConfigId[configId]?[taskID] = nil
                if self.rebuildTasksByConfigId[configId]?.isEmpty == true {
                    self.rebuildTasksByConfigId[configId] = nil
                }
            }

            do {
                defer { self.syncVirtualDisplayState() }
                guard let rebuildExecutor = self.rebuildExecutor else {
                    throw VirtualDisplayRebuildExecutorUnavailableError()
                }
                try await rebuildExecutor(configId, source)
                self.rebuildPresentationState.markRebuildSuccess(configId: configId)
                self.syncRebuildPresentationState()
                self.scheduleAppliedBadgeClear(configId: configId)
                await self.recordEvent(
                    severity: .notice,
                    operation: "Rebuild virtual display",
                    message: "Virtual display rebuild completed.",
                    metadata: ["configID": configId.uuidString],
                    deduplicationKey: "virtualDisplay.rebuild.\(configId.uuidString)"
                )
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled {
                    return
                }
                AppErrorMapper.logFailure(
                    "Rebuild virtual display",
                    error: error,
                    logger: AppLog.virtualDisplay,
                    subsystem: .virtualDisplay,
                    metadata: ["configID": configId.uuidString],
                    deduplicationKey: "virtualDisplay.rebuild.\(configId.uuidString)"
                )
                let message = AppErrorMapper.userMessage(for: error, fallback: String(localized: "Failed to rebuild virtual display."))
                self.rebuildPresentationState.markRebuildFailure(configId: configId, message: message)
                self.syncRebuildPresentationState()
            }
        }
        rebuildTasksByConfigId[configId, default: [:]][taskID] = task
    }

    package func retryRebuild(configId: UUID) {
        startRebuildFromSavedConfig(configId: configId, source: .rowRetry)
    }

    package func setVirtualDisplayDesiredEnabled(
        configId: UUID,
        enabled: Bool,
        source: VirtualDisplayDesiredEnabledRequestSource = .unknown
    ) async throws {
        guard let desiredEnabledExecutor else {
            throw VirtualDisplayDesiredEnabledExecutorUnavailableError()
        }
        defer { syncVirtualDisplayState() }
        try await desiredEnabledExecutor(configId, enabled, source)
    }

    package func saveConfigAndRebuild(
        _ updated: VirtualDisplayConfig,
        expectedConfigFingerprint: String,
        source: VirtualDisplayRebuildRequestSource = .unknown
    ) async throws -> VirtualDisplayEditRebuildTransactionHandle {
        guard let editRebuildExecutor else {
            throw VirtualDisplayEditRebuildExecutorUnavailableError()
        }
        defer { syncVirtualDisplayState() }
        return try await editRebuildExecutor(updated, expectedConfigFingerprint, source)
    }

    package func startEditRebuildPresentation(
        configId: UUID,
        handle: VirtualDisplayEditRebuildTransactionHandle
    ) {
        rebuildRequestCount += 1

        incrementRebuildPresentationWaiter(configId: configId)
        appliedBadgeClearTasksByConfigId[configId]?.cancel()
        appliedBadgeClearTasksByConfigId[configId] = nil
        Task {
            await recordEvent(
                severity: .info,
                operation: "Rebuild virtual display",
                message: "Started rebuild request.",
                metadata: ["configID": configId.uuidString],
                deduplicationKey: "virtualDisplay.rebuild.\(configId.uuidString)"
            )
        }

        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.decrementRebuildPresentationWaiter(configId: configId)
                self.rebuildTasksByConfigId[configId]?[taskID] = nil
                if self.rebuildTasksByConfigId[configId]?.isEmpty == true {
                    self.rebuildTasksByConfigId[configId] = nil
                }
            }

            do {
                defer { self.syncVirtualDisplayState() }
                let result = try await handle.waitForTerminalResult()
                guard result.status != .failed && result.status != .cancelled else {
                    throw VirtualDisplayEditRebuildPresentationError()
                }
                self.rebuildPresentationState.markRebuildSuccess(configId: configId)
                self.syncRebuildPresentationState()
                self.scheduleAppliedBadgeClear(configId: configId)
                await self.recordEvent(
                    severity: .notice,
                    operation: "Rebuild virtual display",
                    message: "Virtual display rebuild completed.",
                    metadata: ["configID": configId.uuidString],
                    deduplicationKey: "virtualDisplay.rebuild.\(configId.uuidString)"
                )
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled {
                    return
                }
                AppErrorMapper.logFailure(
                    "Rebuild virtual display",
                    error: error,
                    logger: AppLog.virtualDisplay,
                    subsystem: .virtualDisplay,
                    metadata: ["configID": configId.uuidString],
                    deduplicationKey: "virtualDisplay.rebuild.\(configId.uuidString)"
                )
                let message = AppErrorMapper.userMessage(for: error, fallback: String(localized: "Failed to rebuild virtual display."))
                self.rebuildPresentationState.markRebuildFailure(configId: configId, message: message)
                self.syncRebuildPresentationState()
            }
        }
        rebuildTasksByConfigId[configId, default: [:]][taskID] = task
    }

    package func isRebuilding(configId: UUID) -> Bool {
        rebuildingConfigIds.contains(configId)
    }

    package func rebuildFailureMessage(configId: UUID) -> String? {
        rebuildFailureMessageByConfigId[configId]
    }

    package func hasRecentApplySuccess(configId: UUID) -> Bool {
        recentlyAppliedConfigIds.contains(configId)
    }

    package func clearRebuildPresentationState(configId: UUID) {
        if let tasks = rebuildTasksByConfigId[configId] {
            for task in tasks.values {
                task.cancel()
            }
        }
        rebuildTasksByConfigId[configId] = nil
        rebuildPresentationWaiterCountByConfigId[configId] = nil
        appliedBadgeClearTasksByConfigId[configId]?.cancel()
        appliedBadgeClearTasksByConfigId[configId] = nil
        rebuildPresentationState.clear(configId: configId)
        syncRebuildPresentationState()
    }

    @discardableResult
    package func createVirtualDisplay(_ request: VirtualDisplayCreateRequest) async throws -> UUID? {
        dismissPersistenceAlert()
        do {
            guard let createExecutor else {
                throw VirtualDisplayCreateExecutorUnavailableError()
            }
            let result = try await createExecutor(request)
            guard result.status != .failed,
                  result.status != .cancelled,
                  result.virtualDisplayCommandSucceeded
            else {
                throw VirtualDisplayRuntimeCommandPresentationError()
            }
            syncVirtualDisplayState()
            if let configID = result.createdConfigID {
                await recordEvent(
                    severity: .notice,
                    operation: "Create virtual display",
                    message: "Created virtual display configuration.",
                    metadata: [
                        "configID": configID.uuidString,
                        "serialNumber": "\(request.serialNumber)"
                    ]
                )
            }
            return result.createdConfigID
        } catch {
            syncVirtualDisplayState()
            recordPersistenceFailure(
                title: String(localized: "Create Failed"),
                operation: "Create virtual display",
                error: error,
                fallback: String(localized: "Create failed.")
            )
            throw error
        }
    }

    package func deleteVirtualDisplay(configId: UUID) async throws {
        guard let deleteExecutor else {
            throw VirtualDisplayDeleteExecutorUnavailableError()
        }
        let result = try await deleteExecutor(configId)
        guard result.status != .failed,
              result.status != .cancelled,
              result.virtualDisplayCommandSucceeded
        else {
            throw VirtualDisplayRuntimeCommandPresentationError()
        }
        clearRebuildPresentationState(configId: configId)
        syncVirtualDisplayState()
        await recordEvent(
            severity: .notice,
            operation: "Delete virtual display",
            message: "Deleted virtual display configuration.",
            metadata: ["configID": configId.uuidString]
        )
    }

    package func getConfig(_ configId: UUID) -> VirtualDisplayConfig? {
        displayConfigs.first { $0.id == configId }
    }

    package func updateConfig(_ updated: VirtualDisplayConfig) throws {
        try performPersistenceAction(
            title: String(localized: "Save Failed"),
            operation: "Update virtual display config",
            fallback: String(localized: "Failed to save display settings.")
        ) {
            try mutateAndSync {
                try virtualDisplayFacade.updateConfig(updated)
            }
        }
        Task {
            await recordEvent(
                severity: .notice,
                operation: "Update virtual display config",
                message: "Updated virtual display configuration.",
                metadata: [
                    "configID": updated.id.uuidString
                ]
            )
        }
    }

    @discardableResult
    package func moveDisplayConfig(_ configId: UUID, direction: VirtualDisplayReorderDirection) throws -> Bool {
        dismissPersistenceAlert()
        defer { syncVirtualDisplayState() }
        let firstEnabledBeforeMove = firstEnabledDesiredConfigID(in: displayConfigs)
        let moved: Bool
        do {
            moved = try virtualDisplayFacade.moveConfig(configId, direction: direction)
        } catch {
            let operation: String
            switch direction {
            case .up:
                operation = "Move virtual display up"
            case .down:
                operation = "Move virtual display down"
            }
            recordPersistenceFailure(
                title: String(localized: "Save Failed"),
                operation: operation,
                error: error,
                fallback: String(localized: "Failed to save virtual display changes.")
            )
            throw error
        }
        if moved { handlePostReorderMainPolicyReconcile(firstEnabledBeforeMove: firstEnabledBeforeMove) }
        return moved
    }

    @discardableResult
    package func setPrimaryVirtualDisplayByReordering(_ configId: UUID) throws -> Bool {
        dismissPersistenceAlert()
        defer { syncVirtualDisplayState() }
        let firstEnabledBeforeMove = firstEnabledDesiredConfigID(in: displayConfigs)
        let moved: Bool
        do {
            moved = try virtualDisplayFacade.moveConfigToFirstEnabledPosition(configId)
        } catch {
            recordPersistenceFailure(
                title: String(localized: "Save Failed"),
                operation: "Set primary virtual display",
                error: error,
                fallback: String(localized: "Failed to save virtual display changes.")
            )
            throw error
        }
        if moved { handlePostReorderMainPolicyReconcile(firstEnabledBeforeMove: firstEnabledBeforeMove) }
        return moved
    }

    package func applyModes(configId: UUID, modes: [ResolutionSelection]) {
        mutateAndSync {
            virtualDisplayFacade.applyModes(configId: configId, modes: modes)
        }
    }

    package func nextAvailableSerialNumber() -> UInt32 {
        virtualDisplayFacade.nextAvailableSerialNumber()
    }

    @discardableResult
    package func resetVirtualDisplayData() throws -> Int {
        let removed = try performPersistenceAction(
            title: String(localized: "Reset Failed"),
            operation: "Reset virtual display configurations",
            fallback: String(localized: "Failed to reset virtual display configurations.")
        ) {
            let removed = try mutateAndSync {
                try virtualDisplayFacade.resetAllVirtualDisplayData()
            }
            clearAllRebuildPresentationState()
            return removed
        }
        Task {
            await recordEvent(
                severity: .notice,
                operation: "Reset virtual display configurations",
                message: "Reset virtual display data.",
                metadata: ["removedCount": "\(removed)"]
            )
        }
        return removed
    }

    private func syncVirtualDisplayState() {
        virtualDisplaySnapshot = virtualDisplayFacade.snapshot
        requestSnapshotRefresh()
    }

    private func syncRebuildPresentationState() {
        requestSnapshotRefresh()
    }

    private func mutateAndSync(_ mutation: () -> Void) {
        mutation()
        syncVirtualDisplayState()
    }

    private func mutateAndSync<T>(_ mutation: () throws -> T) rethrows -> T {
        defer { syncVirtualDisplayState() }
        return try mutation()
    }

    private func mutateAndSync<T>(_ mutation: () async -> T) async -> T {
        defer { syncVirtualDisplayState() }
        return await mutation()
    }

    private func mutateAndSync<T>(_ mutation: () async throws -> T) async rethrows -> T {
        defer { syncVirtualDisplayState() }
        return try await mutation()
    }

    private func performPersistenceAction<T>(
        title: String,
        operation: String,
        fallback: String,
        mutation: () throws -> T
    ) throws -> T {
        dismissPersistenceAlert()
        do {
            return try mutation()
        } catch {
            recordPersistenceFailure(title: title, operation: operation, error: error, fallback: fallback)
            throw error
        }
    }

    private func recordPersistenceFailure(
        title: String,
        operation: String,
        error: Error,
        fallback: String
    ) {
        AppErrorMapper.logFailure(
            operation,
            error: error,
            logger: AppLog.virtualDisplay,
            subsystem: .virtualDisplay
        )
        persistenceAlert = UserFacingAlertState(
            title: title,
            message: AppErrorMapper.userMessage(for: error, fallback: fallback)
        )
    }

    private func incrementRebuildPresentationWaiter(configId: UUID) {
        let currentCount = rebuildPresentationWaiterCountByConfigId[configId] ?? 0
        rebuildPresentationWaiterCountByConfigId[configId] = currentCount + 1
        if currentCount == 0 {
            rebuildPresentationState.beginRebuild(configId: configId)
        }
        syncRebuildPresentationState()
    }

    private func decrementRebuildPresentationWaiter(configId: UUID) {
        let currentCount = rebuildPresentationWaiterCountByConfigId[configId] ?? 0
        let nextCount = max(0, currentCount - 1)
        if nextCount == 0 {
            rebuildPresentationWaiterCountByConfigId[configId] = nil
            rebuildPresentationState.finishRebuild(configId: configId)
        } else {
            rebuildPresentationWaiterCountByConfigId[configId] = nextCount
        }
        syncRebuildPresentationState()
    }

    private func scheduleAppliedBadgeClear(configId: UUID) {
        appliedBadgeClearTasksByConfigId[configId]?.cancel()
        appliedBadgeClearTasksByConfigId[configId] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.appliedBadgeDisplayDuration ?? .seconds(2.5))
            } catch {
                return
            }
            guard let self else { return }
            self.rebuildPresentationState.clearRecentApply(configId: configId)
            self.syncRebuildPresentationState()
            self.appliedBadgeClearTasksByConfigId[configId] = nil
        }
    }

    private func clearAllRebuildPresentationState() {
        let allConfigIds = rebuildPresentationState.allConfigIds(
            extra: Set(rebuildTasksByConfigId.keys).union(Set(appliedBadgeClearTasksByConfigId.keys))
        )

        for configId in allConfigIds {
            clearRebuildPresentationState(configId: configId)
        }
    }

    private func firstEnabledDesiredConfigID(in configs: [VirtualDisplayConfig]) -> UUID? {
        configs.first(where: \.desiredEnabled)?.id
    }

    private func handlePostReorderMainPolicyReconcile(firstEnabledBeforeMove: UUID?) {
        syncVirtualDisplayState()
        let firstEnabledAfterMove = firstEnabledDesiredConfigID(in: displayConfigs)
        guard firstEnabledBeforeMove != firstEnabledAfterMove else {
            AppLog.virtualDisplay.debug(
                "Skip main display policy reconcile after reorder because first enabled config did not change (before: \(String(describing: firstEnabledBeforeMove?.uuidString), privacy: .public), after: \(String(describing: firstEnabledAfterMove?.uuidString), privacy: .public))."
            )
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.virtualDisplayFacade.reconcileMainDisplayPolicyIfNeeded()
            } catch {
                AppErrorMapper.logFailure(
                    "Reconcile virtual display main policy",
                    error: error,
                    logger: AppLog.virtualDisplay,
                    subsystem: .virtualDisplay
                )
            }
            self.syncVirtualDisplayState()
        }
    }

    private func requestSnapshotRefresh() {
        guard let observability else { return }
        Task {
            await observability.refreshSnapshot(reason: .virtualDisplayStateChanged)
        }
    }

    private func recordEvent(
        severity: ObservabilitySeverity,
        operation: String,
        message: String,
        metadata: [String: String],
        deduplicationKey: String? = nil
    ) async {
        await observability?.record(
            ObservabilityEvent(
                severity: severity,
                subsystem: .virtualDisplay,
                operation: operation,
                message: message,
                metadata: metadata,
                deduplicationKey: deduplicationKey
            )
        )
    }
}
