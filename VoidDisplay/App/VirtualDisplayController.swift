//
//  VirtualDisplayController.swift
//  VoidDisplay
//

import Foundation
import CoreGraphics
import Observation
import OSLog

@MainActor
@Observable
final class VirtualDisplayController {
    private(set) var managedDisplays: [ManagedVirtualDisplayRuntimeSnapshot] = []
    private(set) var displayConfigs: [VirtualDisplayConfig] = []
    private(set) var runningConfigIds: Set<UUID> = []
    private(set) var restoreFailures: [VirtualDisplayRestoreFailure] = []
    var persistenceAlert: UserFacingAlertState?
    private(set) var runtimeDisplayIDByConfigId: [UUID: CGDirectDisplayID] = [:]
    private(set) var rebuildingConfigIds: Set<UUID> = []
    private(set) var rebuildFailureMessageByConfigId: [UUID: String] = [:]
    private(set) var recentlyAppliedConfigIds: Set<UUID> = []
    private(set) var configStorePresentation = VirtualDisplayConfigStorePresentation()
    private(set) var rebuildRequestCount = 0

    @ObservationIgnored private let virtualDisplayFacade: any VirtualDisplayFacade
    @ObservationIgnored private var rebuildTasksByConfigId: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var appliedBadgeClearTasksByConfigId: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var rebuildPresentationState = RebuildPresentationState()
    @ObservationIgnored private let appliedBadgeDisplayDuration: Duration
    @ObservationIgnored private let stopDependentStreamsBeforeRebuild: (CGDirectDisplayID) -> Void
    @ObservationIgnored private weak var observability: ObservabilityCenter?

    init(
        virtualDisplayFacade: any VirtualDisplayFacade,
        appliedBadgeDisplayDuration: Duration,
        stopDependentStreamsBeforeRebuild: @escaping (CGDirectDisplayID) -> Void,
        observability: ObservabilityCenter? = nil
    ) {
        self.virtualDisplayFacade = virtualDisplayFacade
        self.appliedBadgeDisplayDuration = appliedBadgeDisplayDuration
        self.stopDependentStreamsBeforeRebuild = stopDependentStreamsBeforeRebuild
        self.observability = observability
        syncVirtualDisplayState()
    }

    func loadPersistedConfigsAndRestoreDesiredVirtualDisplays() {
        virtualDisplayFacade.loadPersistedConfigs()
        virtualDisplayFacade.restoreDesiredVirtualDisplays()
        syncVirtualDisplayState()
        Task {
            if restoreFailures.isEmpty {
                await recordEvent(
                    severity: .info,
                    operation: "Restore virtual displays",
                    message: "Loaded persisted virtual display state.",
                    metadata: ["configCount": "\(displayConfigs.count)"]
                )
            } else {
                for failure in restoreFailures {
                    await observability?.record(
                        error: NSError(
                            domain: ObservabilityDomain.virtualDisplay.rawValue,
                            code: 0,
                            userInfo: [NSLocalizedDescriptionKey: failure.message]
                        ),
                        subsystem: .virtualDisplay,
                        operation: "Restore virtual displays",
                        context: .init(
                            metadata: ["configID": failure.id.uuidString],
                            deduplicationKey: "virtualDisplay.restore.\(failure.id.uuidString)",
                            message: failure.message
                        )
                    )
                }
            }
        }
    }

    func applyUITestPresentationState(scenario: UITestScenario) {
        rebuildPresentationState = RebuildPresentationState()

        for task in rebuildTasksByConfigId.values {
            task.cancel()
        }
        rebuildTasksByConfigId.removeAll()

        for task in appliedBadgeClearTasksByConfigId.values {
            task.cancel()
        }
        appliedBadgeClearTasksByConfigId.removeAll()
        rebuildRequestCount = 0

        switch scenario {
        case .baseline:
            break
        case .capturePreviewDiagnostics:
            break
        case .displayCatalogLoading:
            break
        case .permissionDenied:
            break
        case .settingsFeedback:
            break
        case .virtualDisplayRebuilding:
            if let firstID = displayConfigs.first?.id {
                rebuildPresentationState.beginRebuild(configId: firstID)
            }
        case .virtualDisplayRebuildFailed:
            if let firstID = displayConfigs.first?.id {
                rebuildPresentationState.markRebuildFailure(
                    configId: firstID,
                    message: String(localized: "Failed to rebuild virtual display.")
                )
            }
        case .virtualDisplayRebuildPending:
            break
        }

        syncRebuildPresentationState()
    }

    func runtimeDisplayID(for configId: UUID) -> CGDirectDisplayID? {
        runtimeDisplayIDByConfigId[configId]
    }

    func isManagedVirtualDisplay(displayID: CGDirectDisplayID) -> Bool {
        managedDisplays.contains(where: { $0.displayID == displayID })
    }

    func virtualSerialForManagedDisplay(_ displayID: CGDirectDisplayID) -> UInt32? {
        managedDisplays.first(where: { $0.displayID == displayID })?.serialNum
    }

    func isVirtualDisplayRunning(configId: UUID) -> Bool {
        runningConfigIds.contains(configId)
    }

    func clearRestoreFailures() {
        mutateAndSync {
            virtualDisplayFacade.clearRestoreFailures()
        }
    }

    func dismissPersistenceAlert() {
        persistenceAlert = nil
    }

    func configureObservability(_ observability: ObservabilityCenter?) {
        self.observability = observability
        requestSnapshotRefresh()
    }

    func startRebuildFromSavedConfig(configId: UUID) {
        guard !rebuildingConfigIds.contains(configId) else { return }
        guard getConfig(configId) != nil else {
            clearRebuildPresentationState(configId: configId)
            return
        }
        rebuildRequestCount += 1

        if let runtimeDisplayID = runtimeDisplayIDByConfigId[configId] {
            var displayIDsToStop: Set<CGDirectDisplayID> = [runtimeDisplayID]
            if runtimeDisplayID == CGMainDisplayID(), managedDisplays.count >= 2 {
                displayIDsToStop.formUnion(managedDisplays.map(\.displayID))
            }
            for displayID in displayIDsToStop {
                stopDependentStreamsBeforeRebuild(displayID)
            }
        }

        rebuildPresentationState.beginRebuild(configId: configId)
        syncRebuildPresentationState()
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

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.rebuildPresentationState.finishRebuild(configId: configId)
                self.syncRebuildPresentationState()
                self.rebuildTasksByConfigId[configId] = nil
            }

            do {
                try await self.rebuildVirtualDisplay(configId: configId)
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
        rebuildTasksByConfigId[configId] = task
    }

    func retryRebuild(configId: UUID) {
        startRebuildFromSavedConfig(configId: configId)
    }

    func isRebuilding(configId: UUID) -> Bool {
        rebuildingConfigIds.contains(configId)
    }

    func rebuildFailureMessage(configId: UUID) -> String? {
        rebuildFailureMessageByConfigId[configId]
    }

    func hasRecentApplySuccess(configId: UUID) -> Bool {
        recentlyAppliedConfigIds.contains(configId)
    }

    func clearRebuildPresentationState(configId: UUID) {
        rebuildTasksByConfigId[configId]?.cancel()
        rebuildTasksByConfigId[configId] = nil
        appliedBadgeClearTasksByConfigId[configId]?.cancel()
        appliedBadgeClearTasksByConfigId[configId] = nil
        rebuildPresentationState.clear(configId: configId)
        syncRebuildPresentationState()
    }

    @discardableResult
    func createDisplay(
        name: String,
        serialNum: UInt32,
        physicalSize: CGSize,
        maxPixels: (width: UInt32, height: UInt32),
        modes: [ResolutionSelection]
    ) throws -> UUID {
        let configID = try performPersistenceAction(
            title: String(localized: "Create Failed"),
            operation: "Create virtual display",
            fallback: String(localized: "Create failed.")
        ) {
            try mutateAndSync {
                try virtualDisplayFacade.createDisplay(
                    name: name,
                    serialNum: serialNum,
                    physicalSize: physicalSize,
                    maxPixels: maxPixels,
                    modes: modes
                )
            }
        }
        Task {
            await recordEvent(
                severity: .notice,
                operation: "Create virtual display",
                message: "Created virtual display configuration.",
                metadata: [
                    "configID": configID.uuidString,
                    "serialNumber": "\(serialNum)"
                ]
            )
        }
        return configID
    }

    func disableDisplayByConfig(_ configId: UUID) throws {
        try mutateAndSync {
            try virtualDisplayFacade.disableDisplayByConfig(configId)
        }
        Task {
            await recordEvent(
                severity: .notice,
                operation: "Disable virtual display",
                message: "Disabled virtual display.",
                metadata: ["configID": configId.uuidString]
            )
        }
    }

    func enableDisplay(_ configId: UUID) async throws {
        try await mutateAndSync {
            try await virtualDisplayFacade.enableDisplay(configId)
        }
        await recordEvent(
            severity: .notice,
            operation: "Enable virtual display",
            message: "Enabled virtual display.",
            metadata: ["configID": configId.uuidString]
        )
    }

    func destroyDisplay(_ configId: UUID) throws {
        try performPersistenceAction(
            title: String(localized: "Delete Failed"),
            operation: "Delete virtual display",
            fallback: String(localized: "Delete failed.")
        ) {
            try mutateAndSync {
                try virtualDisplayFacade.destroyDisplay(configId)
                clearRebuildPresentationState(configId: configId)
            }
        }
        Task {
            await recordEvent(
                severity: .notice,
                operation: "Delete virtual display",
                message: "Deleted virtual display configuration.",
                metadata: ["configID": configId.uuidString]
            )
        }
    }

    func getConfig(_ configId: UUID) -> VirtualDisplayConfig? {
        displayConfigs.first { $0.id == configId }
    }

    func updateConfig(_ updated: VirtualDisplayConfig) throws {
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
    func moveDisplayConfig(_ configId: UUID, direction: VirtualDisplayReorderDirection) throws -> Bool {
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
    func setPrimaryVirtualDisplayByReordering(_ configId: UUID) throws -> Bool {
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

    func applyModes(configId: UUID, modes: [ResolutionSelection]) {
        mutateAndSync {
            virtualDisplayFacade.applyModes(configId: configId, modes: modes)
        }
    }

    func rebuildVirtualDisplay(configId: UUID) async throws {
        try await mutateAndSync {
            try await virtualDisplayFacade.rebuildVirtualDisplay(configId: configId)
        }
    }

    func nextAvailableSerialNumber() -> UInt32 {
        virtualDisplayFacade.nextAvailableSerialNumber()
    }

    @discardableResult
    func resetVirtualDisplayData() throws -> Int {
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
        let snapshot = virtualDisplayFacade.snapshot
        managedDisplays = snapshot.managedDisplays
        displayConfigs = snapshot.configs
        runningConfigIds = snapshot.runningConfigIds
        restoreFailures = snapshot.restoreFailures
        runtimeDisplayIDByConfigId = snapshot.runtimeDisplayIDByConfigId
        configStorePresentation = snapshot.configStorePresentation
        requestSnapshotRefresh()
    }

    private func syncRebuildPresentationState() {
        rebuildingConfigIds = rebuildPresentationState.rebuildingConfigIds
        rebuildFailureMessageByConfigId = rebuildPresentationState.rebuildFailureMessageByConfigId
        recentlyAppliedConfigIds = rebuildPresentationState.recentlyAppliedConfigIds
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
