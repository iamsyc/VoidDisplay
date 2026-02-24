//
//  VirtualDisplayController.swift
//  VoidDisplay
//

import Foundation
import CoreGraphics
import Observation

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
        defer { syncVirtualDisplayState() }
        virtualDisplayService.clearRestoreFailures()
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
        defer { syncVirtualDisplayState() }
        return try virtualDisplayService.createDisplay(
            name: name,
            serialNum: serialNum,
            physicalSize: physicalSize,
            maxPixels: maxPixels,
            modes: modes
        )
    }

    func createDisplayFromConfig(_ config: VirtualDisplayConfig) throws -> CGVirtualDisplay {
        defer { syncVirtualDisplayState() }
        return try virtualDisplayService.createDisplayFromConfig(config)
    }

    func disableDisplay(_ display: CGVirtualDisplay, modes: [ResolutionSelection]) {
        defer { syncVirtualDisplayState() }
        virtualDisplayService.disableDisplay(display, modes: modes)
    }

    func disableDisplayByConfig(_ configId: UUID) throws {
        defer { syncVirtualDisplayState() }
        try virtualDisplayService.disableDisplayByConfig(configId)
    }

    func enableDisplay(_ configId: UUID) async throws {
        // Drop controller-held runtime display references before async enable.
        // This allows service-level teardown/rebuild to release CGVirtualDisplay instances promptly.
        displays.removeAll()
        defer { syncVirtualDisplayState() }
        try await virtualDisplayService.enableDisplay(configId)
    }

    func destroyDisplay(_ configId: UUID) {
        defer { syncVirtualDisplayState() }
        clearRebuildPresentationState(configId: configId)
        virtualDisplayService.destroyDisplay(configId)
    }

    func destroyDisplay(_ display: CGVirtualDisplay) {
        defer { syncVirtualDisplayState() }
        if let config = virtualDisplayService.getConfig(for: display) {
            clearRebuildPresentationState(configId: config.id)
        }
        virtualDisplayService.destroyDisplay(display)
    }

    func getConfig(_ configId: UUID) -> VirtualDisplayConfig? {
        virtualDisplayService.getConfig(configId)
    }

    func updateConfig(_ updated: VirtualDisplayConfig) {
        defer { syncVirtualDisplayState() }
        virtualDisplayService.updateConfig(updated)
    }

    @discardableResult
    func moveDisplayConfig(_ configId: UUID, direction: VirtualDisplayService.ReorderDirection) -> Bool {
        let moved = virtualDisplayService.moveConfig(configId, direction: direction)
        if moved {
            syncVirtualDisplayState()
        }
        return moved
    }

    func applyModes(configId: UUID, modes: [ResolutionSelection]) {
        defer { syncVirtualDisplayState() }
        virtualDisplayService.applyModes(configId: configId, modes: modes)
    }

    func rebuildVirtualDisplay(configId: UUID) async throws {
        displays.removeAll()
        defer { syncVirtualDisplayState() }
        try await virtualDisplayService.rebuildVirtualDisplay(configId: configId)
    }

    func getConfig(for display: CGVirtualDisplay) -> VirtualDisplayConfig? {
        virtualDisplayService.getConfig(for: display)
    }

    func updateConfig(for display: CGVirtualDisplay, modes: [ResolutionSelection]) {
        defer { syncVirtualDisplayState() }
        virtualDisplayService.updateConfig(for: display, modes: modes)
    }

    func nextAvailableSerialNumber() -> UInt32 {
        virtualDisplayService.nextAvailableSerialNumber()
    }

    @discardableResult
    func resetVirtualDisplayData() -> Int {
        clearAllRebuildPresentationState()
        defer { syncVirtualDisplayState() }
        return virtualDisplayService.resetAllVirtualDisplayData()
    }

    private func syncVirtualDisplayState() {
        displays = virtualDisplayService.currentDisplays
        displayConfigs = virtualDisplayService.currentDisplayConfigs
        runningConfigIds = virtualDisplayService.currentRunningConfigIds
        restoreFailures = virtualDisplayService.currentRestoreFailures
    }

    private func syncRebuildPresentationState() {
        rebuildingConfigIds = rebuildPresentationState.rebuildingConfigIds
        rebuildFailureMessageByConfigId = rebuildPresentationState.rebuildFailureMessageByConfigId
        recentlyAppliedConfigIds = rebuildPresentationState.recentlyAppliedConfigIds
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
}
