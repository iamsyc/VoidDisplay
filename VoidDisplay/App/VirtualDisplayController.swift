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
    private(set) var runtimeDisplayIDByConfigId: [UUID: CGDirectDisplayID] = [:]
    private(set) var rebuildingConfigIds: Set<UUID> = []
    private(set) var rebuildFailureMessageByConfigId: [UUID: String] = [:]
    private(set) var recentlyAppliedConfigIds: Set<UUID> = []
    private(set) var configStorePresentation = VirtualDisplayConfigStorePresentation()

    @ObservationIgnored private let virtualDisplayFacade: any VirtualDisplayFacade
    @ObservationIgnored private var rebuildTasksByConfigId: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var appliedBadgeClearTasksByConfigId: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var rebuildPresentationState = RebuildPresentationState()
    @ObservationIgnored private let appliedBadgeDisplayDurationNanoseconds: UInt64
    @ObservationIgnored private let stopDependentStreamsBeforeRebuild: (CGDirectDisplayID) -> Void

    init(
        virtualDisplayFacade: any VirtualDisplayFacade,
        appliedBadgeDisplayDurationNanoseconds: UInt64,
        stopDependentStreamsBeforeRebuild: @escaping (CGDirectDisplayID) -> Void
    ) {
        self.virtualDisplayFacade = virtualDisplayFacade
        self.appliedBadgeDisplayDurationNanoseconds = appliedBadgeDisplayDurationNanoseconds
        self.stopDependentStreamsBeforeRebuild = stopDependentStreamsBeforeRebuild
        syncVirtualDisplayState()
    }

    func loadPersistedConfigsAndRestoreDesiredVirtualDisplays() {
        virtualDisplayFacade.loadPersistedConfigs()
        virtualDisplayFacade.restoreDesiredVirtualDisplays()
        syncVirtualDisplayState()
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

        switch scenario {
        case .baseline:
            break
        case .permissionDenied:
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

    func startRebuildFromSavedConfig(configId: UUID) {
        guard !rebuildingConfigIds.contains(configId) else { return }
        guard getConfig(configId) != nil else {
            clearRebuildPresentationState(configId: configId)
            return
        }

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
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled {
                    return
                }
                AppErrorMapper.logFailure("Rebuild virtual display", error: error, logger: AppLog.virtualDisplay)
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

    func disableDisplayByConfig(_ configId: UUID) throws {
        try mutateAndSync {
            try virtualDisplayFacade.disableDisplayByConfig(configId)
        }
    }

    func enableDisplay(_ configId: UUID) async throws {
        try await mutateAndSync {
            try await virtualDisplayFacade.enableDisplay(configId)
        }
    }

    func destroyDisplay(_ configId: UUID) {
        mutateAndSync {
            clearRebuildPresentationState(configId: configId)
            virtualDisplayFacade.destroyDisplay(configId)
        }
    }

    func getConfig(_ configId: UUID) -> VirtualDisplayConfig? {
        displayConfigs.first { $0.id == configId }
    }

    func updateConfig(_ updated: VirtualDisplayConfig) {
        mutateAndSync {
            virtualDisplayFacade.updateConfig(updated)
        }
    }

    @discardableResult
    func moveDisplayConfig(_ configId: UUID, direction: VirtualDisplayReorderDirection) -> Bool {
        let firstEnabledBeforeMove = firstEnabledDesiredConfigID(in: displayConfigs)
        let moved = virtualDisplayFacade.moveConfig(configId, direction: direction)
        if moved { handlePostReorderMainPolicyReconcile(firstEnabledBeforeMove: firstEnabledBeforeMove) }
        return moved
    }

    @discardableResult
    func setPrimaryVirtualDisplayByReordering(_ configId: UUID) -> Bool {
        let firstEnabledBeforeMove = firstEnabledDesiredConfigID(in: displayConfigs)
        let moved = virtualDisplayFacade.moveConfigToFirstEnabledPosition(configId)
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
    func resetVirtualDisplayData() -> Int {
        clearAllRebuildPresentationState()
        return mutateAndSync {
            virtualDisplayFacade.resetAllVirtualDisplayData()
        }
    }

    private func syncVirtualDisplayState() {
        let snapshot = virtualDisplayFacade.snapshot
        managedDisplays = snapshot.managedDisplays
        displayConfigs = snapshot.configs
        runningConfigIds = snapshot.runningConfigIds
        restoreFailures = snapshot.restoreFailures
        runtimeDisplayIDByConfigId = snapshot.runtimeDisplayIDByConfigId
        configStorePresentation = snapshot.configStorePresentation
    }

    private func syncRebuildPresentationState() {
        rebuildingConfigIds = rebuildPresentationState.rebuildingConfigIds
        rebuildFailureMessageByConfigId = rebuildPresentationState.rebuildFailureMessageByConfigId
        recentlyAppliedConfigIds = rebuildPresentationState.recentlyAppliedConfigIds
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

    private func scheduleAppliedBadgeClear(configId: UUID) {
        appliedBadgeClearTasksByConfigId[configId]?.cancel()
        appliedBadgeClearTasksByConfigId[configId] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.appliedBadgeDisplayDurationNanoseconds ?? 2_500_000_000)
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
                    logger: AppLog.virtualDisplay
                )
            }
            self.syncVirtualDisplayState()
        }
    }
}
