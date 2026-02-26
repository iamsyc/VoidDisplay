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
    var displays: [CGVirtualDisplay] = []
    var displayConfigs: [VirtualDisplayConfig] = []
    private(set) var runningConfigIds: Set<UUID> = []
    private(set) var restoreFailures: [VirtualDisplayRestoreFailure] = []
    private(set) var rebuildingConfigIds: Set<UUID> = []
    private(set) var rebuildFailureMessageByConfigId: [UUID: String] = [:]
    private(set) var recentlyAppliedConfigIds: Set<UUID> = []
    private(set) var configStorePresentation = VirtualDisplayConfigStorePresentation()

    @ObservationIgnored private let virtualDisplayService: any VirtualDisplayServiceProtocol
    @ObservationIgnored private var rebuildTasksByConfigId: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var appliedBadgeClearTasksByConfigId: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var rebuildPresentationState = RebuildPresentationState()
    @ObservationIgnored private let appliedBadgeDisplayDurationNanoseconds: UInt64
    @ObservationIgnored private let stopDependentStreamsBeforeRebuild: (CGDirectDisplayID) -> Void

    init(
        virtualDisplayService: any VirtualDisplayServiceProtocol,
        appliedBadgeDisplayDurationNanoseconds: UInt64,
        stopDependentStreamsBeforeRebuild: @escaping (CGDirectDisplayID) -> Void
    ) {
        self.virtualDisplayService = virtualDisplayService
        self.appliedBadgeDisplayDurationNanoseconds = appliedBadgeDisplayDurationNanoseconds
        self.stopDependentStreamsBeforeRebuild = stopDependentStreamsBeforeRebuild
    }

    func loadPersistedConfigsAndRestoreDesiredVirtualDisplays() {
        virtualDisplayService.loadPersistedConfigs()
        virtualDisplayService.restoreDesiredVirtualDisplays()
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

    func runtimeDisplay(for configId: UUID) -> CGVirtualDisplay? {
        virtualDisplayService.runtimeDisplay(for: configId)
    }

    func runtimeDisplayID(for configId: UUID) -> CGDirectDisplayID? {
        virtualDisplayService.runtimeDisplayID(for: configId)
    }

    func isManagedVirtualDisplay(displayID: CGDirectDisplayID) -> Bool {
        displays.contains(where: { $0.displayID == displayID })
    }

    func virtualSerialForManagedDisplay(_ displayID: CGDirectDisplayID) -> UInt32? {
        displays.first(where: { $0.displayID == displayID })?.serialNum
    }

    func isVirtualDisplayRunning(configId: UUID) -> Bool {
        virtualDisplayService.isVirtualDisplayRunning(configId: configId)
    }

    func clearRestoreFailures() {
        mutateAndSync {
            virtualDisplayService.clearRestoreFailures()
        }
    }

    func startRebuildFromSavedConfig(configId: UUID) {
        guard !rebuildingConfigIds.contains(configId) else { return }
        guard getConfig(configId) != nil else {
            clearRebuildPresentationState(configId: configId)
            return
        }

        if let runtimeDisplayID = virtualDisplayService.runtimeDisplayID(for: configId) {
            var displayIDsToStop: Set<CGDirectDisplayID> = [runtimeDisplayID]
            if runtimeDisplayID == CGMainDisplayID(), displays.count >= 2 {
                displayIDsToStop.formUnion(displays.map(\.displayID))
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
    ) throws -> CGVirtualDisplay {
        try mutateAndSync {
            try virtualDisplayService.createDisplay(
                name: name,
                serialNum: serialNum,
                physicalSize: physicalSize,
                maxPixels: maxPixels,
                modes: modes
            )
        }
    }

    func createDisplayFromConfig(_ config: VirtualDisplayConfig) throws -> CGVirtualDisplay {
        try mutateAndSync {
            try virtualDisplayService.createDisplayFromConfig(config)
        }
    }

    func disableDisplay(_ display: CGVirtualDisplay, modes: [ResolutionSelection]) {
        mutateAndSync {
            virtualDisplayService.disableDisplay(display, modes: modes)
        }
    }

    func disableDisplayByConfig(_ configId: UUID) throws {
        try mutateAndSync {
            try virtualDisplayService.disableDisplayByConfig(configId)
        }
    }

    func enableDisplay(_ configId: UUID) async throws {
        // Drop controller-held runtime display references before async enable.
        // This allows service-level teardown/rebuild to release CGVirtualDisplay instances promptly.
        displays.removeAll()
        try await mutateAndSync {
            try await virtualDisplayService.enableDisplay(configId)
        }
    }

    func destroyDisplay(_ configId: UUID) {
        mutateAndSync {
            clearRebuildPresentationState(configId: configId)
            virtualDisplayService.destroyDisplay(configId)
        }
    }

    func destroyDisplay(_ display: CGVirtualDisplay) {
        mutateAndSync {
            if let config = virtualDisplayService.getConfig(for: display) {
                clearRebuildPresentationState(configId: config.id)
            }
            virtualDisplayService.destroyDisplay(display)
        }
    }

    func getConfig(_ configId: UUID) -> VirtualDisplayConfig? {
        virtualDisplayService.getConfig(configId)
    }

    func updateConfig(_ updated: VirtualDisplayConfig) {
        mutateAndSync {
            virtualDisplayService.updateConfig(updated)
        }
    }

    @discardableResult
    func moveDisplayConfig(_ configId: UUID, direction: VirtualDisplayReorderDirection) -> Bool {
        let firstEnabledBeforeMove = firstEnabledDesiredConfigID(in: displayConfigs)
        let moved = virtualDisplayService.moveConfig(configId, direction: direction)
        if moved { handlePostReorderMainPolicyReconcile(firstEnabledBeforeMove: firstEnabledBeforeMove) }
        return moved
    }

    @discardableResult
    func setPrimaryVirtualDisplayByReordering(_ configId: UUID) -> Bool {
        let firstEnabledBeforeMove = firstEnabledDesiredConfigID(in: displayConfigs)
        let moved = virtualDisplayService.moveConfigToFirstEnabledPosition(configId)
        if moved { handlePostReorderMainPolicyReconcile(firstEnabledBeforeMove: firstEnabledBeforeMove) }
        return moved
    }

    func applyModes(configId: UUID, modes: [ResolutionSelection]) {
        mutateAndSync {
            virtualDisplayService.applyModes(configId: configId, modes: modes)
        }
    }

    func rebuildVirtualDisplay(configId: UUID) async throws {
        displays.removeAll()
        try await mutateAndSync {
            try await virtualDisplayService.rebuildVirtualDisplay(configId: configId)
        }
    }

    func getConfig(for display: CGVirtualDisplay) -> VirtualDisplayConfig? {
        virtualDisplayService.getConfig(for: display)
    }

    func updateConfig(for display: CGVirtualDisplay, modes: [ResolutionSelection]) {
        mutateAndSync {
            virtualDisplayService.updateConfig(for: display, modes: modes)
        }
    }

    func nextAvailableSerialNumber() -> UInt32 {
        virtualDisplayService.nextAvailableSerialNumber()
    }

    @discardableResult
    func resetVirtualDisplayData() -> Int {
        clearAllRebuildPresentationState()
        return mutateAndSync {
            virtualDisplayService.resetAllVirtualDisplayData()
        }
    }

    private func syncVirtualDisplayState() {
        displays = virtualDisplayService.currentDisplays
        displayConfigs = virtualDisplayService.currentDisplayConfigs
        runningConfigIds = virtualDisplayService.currentRunningConfigIds
        restoreFailures = virtualDisplayService.currentRestoreFailures
        configStorePresentation = virtualDisplayService.configStorePresentation
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
                try await self.virtualDisplayService.reconcileMainDisplayPolicyIfNeeded()
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
