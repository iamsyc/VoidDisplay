import VoidDisplayCapture
import VoidDisplayFoundation
import VoidDisplayObservability
import VoidDisplayRuntime
import VoidDisplaySharing
import VoidDisplayVirtualDisplay
import Foundation
import ScreenCaptureKit

@MainActor
package final class DisplayRuntimeCatalogAdapter: DisplayRuntimeCatalogProviding, DisplayRuntimeCatalogCommanding {
    private let service: ScreenCaptureCatalogService
    private let captureRefreshOwner = ScreenCaptureCatalogService.RefreshOwner()
    private let sharingRefreshOwner = ScreenCaptureCatalogService.RefreshOwner()

    package init(service: ScreenCaptureCatalogService) {
        self.service = service
    }

    package func makeCatalogSnapshot() -> DisplayRuntimeCatalogSnapshot {
        let store = service.store
        return DisplayRuntimeCatalogSnapshot(
            hasScreenCapturePermission: store.hasScreenCapturePermission,
            lastPreflightPermission: store.lastPreflightPermission,
            lastRequestPermission: store.lastRequestPermission,
            isLoadingDisplays: store.isLoadingDisplays,
            hasLoadError: store.loadErrorMessage != nil || store.lastLoadError != nil,
            lastLoadError: store.lastLoadError.map {
                .init(
                    domain: $0.domain,
                    code: $0.code,
                    hasDescription: !$0.description.isEmpty,
                    hasFailureReason: $0.failureReason != nil,
                    hasRecoverySuggestion: $0.recoverySuggestion != nil
                )
            },
            loadedDisplays: (store.displays ?? []).map {
                .init(
                    displayID: $0.displayID,
                    pixelWidth: $0.width,
                    pixelHeight: $0.height
                )
            },
            topologySignature: (store.lastLoadedActiveDisplayTopologySignature ?? []).map {
                .init(
                    displayID: $0.displayID,
                    isMain: $0.isMain,
                    pixelWidth: $0.pixelWidth,
                    pixelHeight: $0.pixelHeight,
                    refreshRateMilliHertz: $0.refreshRateMilliHertz,
                    mirrorsDisplayID: $0.mirrorsDisplayID
                )
            }
        )
    }

    package func requestPermission() -> Bool {
        service.requestPermission()
    }

    package func refreshPermission() -> Bool {
        service.refreshPermission()
    }

    package func submitRefresh(
        intent: DisplayRuntimeCatalogRefreshIntent,
        ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?
    ) async -> DisplayRuntimeCatalogRefreshResult {
        let result = await service.submitRefresh(
            intent: ScreenCaptureCatalogRefreshIntent(intent),
            owner: owner(for: ownerScope)
        )
        return DisplayRuntimeCatalogRefreshResult(result)
    }

    package func clearSnapshotForDeniedPermission(loadErrorMessage: String?) async {
        await service.clearSnapshotForDeniedPermission(loadErrorMessage: loadErrorMessage)
    }

    package func cancelRefresh(ownerScope: DisplayRuntimeCatalogRefreshOwnerScope?) async {
        await service.cancelRefresh(owner: owner(for: ownerScope))
    }

    package func currentVisibleDisplays() -> [DisplayRuntimeVisibleDisplay] {
        return service.visibleDisplays(from: service.store.displays ?? []).map {
            DisplayRuntimeVisibleDisplay(
                displayID: $0.displayID,
                pixelWidth: $0.width,
                pixelHeight: $0.height
            )
        }
    }

    private func owner(
        for scope: DisplayRuntimeCatalogRefreshOwnerScope?
    ) -> ScreenCaptureCatalogService.RefreshOwner? {
        switch scope {
        case .capture:
            captureRefreshOwner
        case .sharing:
            sharingRefreshOwner
        case nil:
            nil
        }
    }
}

@MainActor
package final class DisplayRuntimeCaptureAdapter: DisplayRuntimeCaptureProviding, DisplayRuntimeCaptureCommanding {
    private weak var controller: CaptureController?

    package init(controller: CaptureController) {
        self.controller = controller
    }

    package func makeCaptureSnapshot() -> DisplayRuntimeCaptureSnapshot {
        guard let controller else { return .empty }
        return DisplayRuntimeCaptureSnapshot(
            startingDisplayIDs: controller.startingDisplayIDs.sorted(),
            sessions: controller.screenCaptureSessions.map { session in
                let metrics = session.previewSubscription.captureMetricsSnapshot()
                return DisplayRuntimeCaptureSession(
                    id: session.id,
                    displayID: session.displayID,
                    isVirtualDisplay: session.isVirtualDisplay,
                    capturesCursor: session.capturesCursor,
                    state: session.state == .starting ? .starting : .active,
                    metrics: .init(
                        currentProfile: metrics.currentProfile?.rawValue,
                        currentFrameRateTier: metrics.currentFrameRateTier.map { "\($0.framesPerSecond)fps" },
                        receivedFrameCount: metrics.receivedFrameCount,
                        profileReconfigurationCount: metrics.profileReconfigurationCount,
                        cursorOverrideReconfigurationCount: metrics.cursorOverrideReconfigurationCount
                    )
                )
            }
        )
    }

    package func removeMonitoringSessions(displayID: DisplayRuntimeDisplayID) {
        controller?.removeMonitoringSessions(displayID: displayID)
    }
}

@MainActor
package final class DisplayRuntimeSharingAdapter: DisplayRuntimeSharingProviding, DisplayRuntimeSharingCommanding {
    private weak var controller: SharingController?

    package init(controller: SharingController) {
        self.controller = controller
    }

    package func makeSharingSnapshot() -> DisplayRuntimeSharingSnapshot {
        guard let controller else { return .empty }
        let displayIDsWithRouteProbe = Set((controller.displayCatalogState.displays ?? []).map(\.displayID))
            .union(controller.activeSharingDisplayIDs)
            .union(controller.startingDisplayIDs)
            .union(controller.sharingClientCounts.keys)
        return DisplayRuntimeSharingSnapshot(
            activeSharingDisplayIDs: controller.activeSharingDisplayIDs.sorted(),
            startingDisplayIDs: controller.startingDisplayIDs.sorted(),
            isSharing: controller.isSharing,
            isWebServiceRunning: controller.isWebServiceRunning,
            preferredPort: controller.preferredWebServicePort,
            sharingClientCount: controller.sharingClientCount,
            sharingClientCounts: controller.sharingClientCounts.map {
                DisplayRuntimeDisplayClientCount(displayID: $0.key, count: $0.value)
            },
            lifecycle: DisplayRuntimeSharingLifecycle(state: controller.webServiceLifecycleState),
            routes: displayIDsWithRouteProbe.map {
                DisplayRuntimeShareRoute(displayID: $0, hasConcreteRoute: controller.sharePagePath(for: $0) != nil)
            }
        )
    }

    package func registerShareableDisplays(_ displays: [DisplayRuntimeShareableDisplayRegistration]) {
        guard let controller else { return }
        let registrationsByDisplayID = firstRegistrationsByDisplayID(displays)
        let visibleDisplays = (controller.displayCatalogState.displays ?? []).filter {
            registrationsByDisplayID[$0.displayID] != nil
        }
        controller.registerShareableDisplays(visibleDisplays) { displayID in
            registrationsByDisplayID[displayID]?.virtualSerialNumber
        }
    }

    package func stopSharing(displayID: DisplayRuntimeDisplayID) {
        controller?.stopSharing(displayID: displayID)
    }

    package func restoreSharing(displayID: DisplayRuntimeDisplayID) async -> DisplayRuntimeSharingRestoreCommandResult {
        guard let controller else {
            return .failed("sharing_controller_unavailable")
        }
        guard controller.isWebServiceRunning else {
            return .init(status: .skipped, failureReason: "web_service_not_running")
        }
        guard let display = (controller.displayCatalogState.displays ?? []).first(where: { $0.displayID == displayID }) else {
            return .failed("display_not_found")
        }
        guard controller.sharePagePath(for: displayID) != nil else {
            return .failed("shareable_display_not_registered")
        }

        do {
            switch try await controller.beginSharing(display: display) {
            case .started:
                return .restored
            case .invalidated:
                return .invalidated("sharing_start_invalidated")
            }
        } catch {
            return .failed(String(describing: error))
        }
    }

    private func firstRegistrationsByDisplayID(
        _ displays: [DisplayRuntimeShareableDisplayRegistration]
    ) -> [DisplayRuntimeDisplayID: DisplayRuntimeShareableDisplayRegistration] {
        var result: [DisplayRuntimeDisplayID: DisplayRuntimeShareableDisplayRegistration] = [:]
        for display in displays {
            result[display.displayID] = result[display.displayID] ?? display
        }
        return result
    }
}

@MainActor
package final class DisplayRuntimeVirtualDisplayAdapter: DisplayRuntimeVirtualDisplayProviding, DisplayRuntimeVirtualDisplayCommanding {
    private weak var controller: VirtualDisplayController?

    package init(controller: VirtualDisplayController) {
        self.controller = controller
    }

    package func makeVirtualDisplaySnapshot() -> DisplayRuntimeVirtualDisplaySnapshot {
        guard let controller else { return .empty }
        return DisplayRuntimeVirtualDisplaySnapshot(
            rebuildRequestCount: controller.rebuildRequestCount,
            rebuildingConfigIDs: Array(controller.rebuildingConfigIds),
            runningConfigIDs: Array(controller.runningConfigIds),
            recentlyAppliedConfigIDs: Array(controller.recentlyAppliedConfigIds),
            rebuildFailureConfigIDs: Array(controller.rebuildFailureMessageByConfigId.keys),
            configStoreHasLoadFailure: controller.configStorePresentation.hasLoadFailure,
            configStoreHasDiagnostics: controller.configStorePresentation.loadErrorMessage != nil
                || controller.configStorePresentation.diagnosticsSummary != nil,
            managedDisplays: controller.managedDisplays.map {
                .init(
                    configID: $0.configId,
                    serialNumber: $0.serialNum,
                    displayID: $0.displayID,
                    isLiveRuntime: $0.isLiveRuntime
                )
            },
            configs: controller.displayConfigs.map { config in
                .init(
                    id: config.id,
                    serialNumber: config.serialNum,
                    desiredEnabled: config.desiredEnabled,
                    physicalWidthMillimeters: config.physicalWidth,
                    physicalHeightMillimeters: config.physicalHeight,
                    modes: config.modes.map {
                        .init(
                            width: $0.width,
                            height: $0.height,
                            refreshRate: $0.refreshRate,
                            enableHiDPI: $0.enableHiDPI
                        )
                    }
                )
            },
            restoreFailureConfigIDs: controller.restoreFailures.map(\.id)
        )
    }

    package func rebuildVirtualDisplay(configID: UUID) async throws -> DisplayRuntimeVirtualDisplayRebuildCommandResult {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        let preDisplayID = controller.runtimeDisplayID(for: configID)
        try await controller.rebuildVirtualDisplay(configId: configID)
        return DisplayRuntimeVirtualDisplayRebuildCommandResult(
            configID: configID,
            preDisplayID: preDisplayID,
            postDisplayID: controller.runtimeDisplayID(for: configID),
            runningConfigIDsAfterCommand: Array(controller.runningConfigIds),
            managedDisplaysAfterCommand: controller.managedDisplays.map {
                .init(
                    configID: $0.configId,
                    serialNumber: $0.serialNum,
                    displayID: $0.displayID,
                    isLiveRuntime: $0.isLiveRuntime
                )
            }
        )
    }

    package func preflightEnableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayEnablePreflight {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        let preflight = controller.enableDisplayPreflight(request.configID)
        return DisplayRuntimeVirtualDisplayEnablePreflight(
            configID: preflight.configID,
            targetPreDisplayID: preflight.targetPreDisplayID,
            mayPerformFleetRebuild: preflight.mayPerformFleetRebuild,
            requiresFleetQuiesce: preflight.requiresFleetQuiesce,
            scopeEscalationReason: DisplayRuntimeScopeEscalationReason(preflight.scopeEscalationReason)
        )
    }

    package func setVirtualDisplayDesiredEnabled(
        request: DisplayRuntimeVirtualDisplayDesiredEnabledCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayDesiredEnabledCommandResult {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        try controller.setDesiredEnabled(request.configID, enabled: request.enabled)
        return DisplayRuntimeVirtualDisplayDesiredEnabledCommandResult(
            configID: request.configID,
            desiredEnabled: request.enabled,
            persistenceOutcome: .saved
        )
    }

    package func saveConfigForRebuild(
        request: DisplayRuntimeVirtualDisplayEditRebuildRequest
    ) async throws -> DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        let updated = VirtualDisplayConfig(editDTO: request.editedConfig)
        do {
            let previous = try controller.saveConfigForRebuildCommand(
                updated,
                expectedConfigFingerprint: request.expectedConfigFingerprint
            )
            return DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult(
                configID: updated.id,
                persistenceOutcome: .saved,
                previousConfigForCompensation: DisplayRuntimeVirtualDisplayConfigEditDTO(config: previous),
                savedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence(
                    config: DisplayRuntimeVirtualDisplayConfigEditDTO(config: updated)
                )
            )
        } catch VirtualDisplayEditRebuildPersistenceError.editRequestStale {
            throw DisplayRuntimeVirtualDisplayEditRebuildSaveCommandError.editRequestStale
        }
    }

    package func restoreConfigAfterFailedEdit(
        request: DisplayRuntimeVirtualDisplayEditRebuildRestoreCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayPersistenceCommandResult {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        let previous = VirtualDisplayConfig(editDTO: request.previousConfigForCompensation)
        try controller.restoreConfigAfterFailedEditCommand(previous)
        return DisplayRuntimeVirtualDisplayPersistenceCommandResult(
            configID: previous.id,
            persistenceOutcome: .rolledBack
        )
    }

    package func enableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayLifecycleCommandResult {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        let result = try await controller.enableRuntimeDisplay(request.configID)
        return DisplayRuntimeVirtualDisplayLifecycleCommandResult(
            configID: result.configID,
            desiredEnabled: result.desiredEnabled,
            preDisplayID: result.preDisplayID ?? request.targetPreDisplayID,
            postDisplayID: result.postDisplayID,
            runningConfigIDsAfterCommand: Array(controller.runningConfigIds),
            managedDisplaysAfterCommand: controller.managedDisplays.map {
                .init(
                    configID: $0.configId,
                    serialNumber: $0.serialNum,
                    displayID: $0.displayID,
                    isLiveRuntime: $0.isLiveRuntime
                )
            },
            mayPerformFleetRebuild: result.mayPerformFleetRebuild,
            requiresFleetQuiesce: result.requiresFleetQuiesce
        )
    }

    package func disableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayLifecycleCommandResult {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        let result = try controller.disableRuntimeDisplayByConfig(request.configID)
        return DisplayRuntimeVirtualDisplayLifecycleCommandResult(
            configID: result.configID,
            desiredEnabled: result.desiredEnabled,
            preDisplayID: result.preDisplayID ?? request.targetPreDisplayID,
            postDisplayID: result.postDisplayID,
            runningConfigIDsAfterCommand: Array(controller.runningConfigIds),
            managedDisplaysAfterCommand: controller.managedDisplays.map {
                .init(
                    configID: $0.configId,
                    serialNumber: $0.serialNum,
                    displayID: $0.displayID,
                    isLiveRuntime: $0.isLiveRuntime
                )
            },
            mayPerformFleetRebuild: result.mayPerformFleetRebuild,
            requiresFleetQuiesce: result.requiresFleetQuiesce
        )
    }

    package func createVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayCreateRequest
    ) async throws -> DisplayRuntimeVirtualDisplayCreateCommandResult {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        let commandRequest = VirtualDisplayCreateRequest(runtimeRequest: request)
        do {
            let result = try controller.createDisplayCommand(commandRequest)
            return DisplayRuntimeVirtualDisplayCreateCommandResult(
                transactionID: request.transactionID,
                lowerResult: result
            )
        } catch let failure as VirtualDisplayCreateCommandFailure {
            throw DisplayRuntimeVirtualDisplayCreateCommandError(
                reason: failure.reason,
                result: DisplayRuntimeVirtualDisplayCreateCommandResult(
                    transactionID: request.transactionID,
                    lowerResult: failure.result
                )
            )
        }
    }

    package func deleteVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayDeleteCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayDeleteCommandResult {
        guard let controller else {
            throw DisplayRuntimeAdapterError.adapterUnavailable("virtual_display_controller_unavailable")
        }
        do {
            let result = try controller.deleteDisplayCommand(configId: request.configID)
            return DisplayRuntimeVirtualDisplayDeleteCommandResult(
                transactionID: request.transactionID,
                lowerResult: result
            )
        } catch let failure as VirtualDisplayDeleteCommandFailure {
            throw DisplayRuntimeVirtualDisplayDeleteCommandError(
                reason: failure.reason,
                result: DisplayRuntimeVirtualDisplayDeleteCommandResult(
                    transactionID: request.transactionID,
                    lowerResult: failure.result
                )
            )
        }
    }
}

private extension DisplayRuntimeScopeEscalationReason {
    init?(_ reason: VirtualDisplayEnablePreflight.ScopeEscalationReason?) {
        guard let reason else { return nil }
        switch reason {
        case .enableMayPerformFleetRebuild:
            self = .enableMayPerformFleetRebuild
        }
    }
}

private extension VirtualDisplayConfig {
    init(editDTO: DisplayRuntimeVirtualDisplayConfigEditDTO) {
        self.init(
            id: editDTO.id,
            displayName: editDTO.displayName,
            serialNum: editDTO.serialNumber,
            physicalWidth: Int(editDTO.physicalWidthMillimeters),
            physicalHeight: Int(editDTO.physicalHeightMillimeters),
            modes: editDTO.modes.map {
                .init(
                    width: $0.width,
                    height: $0.height,
                    refreshRate: $0.refreshRate,
                    enableHiDPI: $0.enableHiDPI
                )
            },
            desiredEnabled: editDTO.desiredEnabled
        )
    }
}

private extension VirtualDisplayCreateRequest {
    init(runtimeRequest: DisplayRuntimeVirtualDisplayCreateRequest) {
        self.init(
            displayName: runtimeRequest.displayName,
            serialNumber: runtimeRequest.serialNumber,
            physicalWidthMillimeters: runtimeRequest.physicalWidthMillimeters,
            physicalHeightMillimeters: runtimeRequest.physicalHeightMillimeters,
            maximumPixelWidth: runtimeRequest.maximumPixelWidth,
            maximumPixelHeight: runtimeRequest.maximumPixelHeight,
            modes: runtimeRequest.modes.map {
                ResolutionSelection(
                    width: $0.width,
                    height: $0.height,
                    refreshRate: $0.refreshRate,
                    enableHiDPI: $0.enableHiDPI
                )
            }
        )
    }
}

private extension DisplayRuntimeVirtualDisplayCreateCommandResult {
    init(
        transactionID: DisplayRuntimeTransactionID,
        lowerResult: VirtualDisplayCreateCommandResult
    ) {
        self.init(
            transactionID: transactionID,
            createdConfigID: lowerResult.createdConfigID,
            serialNumber: lowerResult.serialNumber,
            targetWasRunningAfterCommand: lowerResult.targetWasRunningAfterCommand,
            preDisplayID: lowerResult.preDisplayID,
            postDisplayID: lowerResult.postDisplayID,
            persistenceOutcome: DisplayRuntimePersistenceOutcome(lowerResult.persistenceOutcome),
            runtimeCreationOutcome: DisplayRuntimeVirtualDisplayCommandOutcome(lowerResult.runtimeCreationOutcome),
            rollbackOutcome: DisplayRuntimePersistenceOutcome(lowerResult.rollbackOutcome),
            createdConfigEvidence: DisplayRuntimeVirtualDisplayCreateConfigEvidence(lowerResult.createdConfigEvidence),
            runningConfigIDsAfterCommand: lowerResult.runningConfigIDsAfterCommand,
            managedDisplaysAfterCommand: lowerResult.managedDisplaysAfterCommand.map(DisplayRuntimeManagedVirtualDisplay.init)
        )
    }
}

private extension DisplayRuntimeVirtualDisplayDeleteCommandResult {
    init(
        transactionID: DisplayRuntimeTransactionID,
        lowerResult: VirtualDisplayDeleteCommandResult
    ) {
        self.init(
            transactionID: transactionID,
            configID: lowerResult.configID,
            targetWasRunning: lowerResult.targetWasRunning,
            preDisplayID: lowerResult.preDisplayID,
            postDisplayID: lowerResult.postDisplayID,
            persistenceOutcome: DisplayRuntimePersistenceOutcome(lowerResult.persistenceOutcome),
            virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome(lowerResult.virtualDisplayCommandOutcome),
            runtimeTrackingClearOutcome: DisplayRuntimeVirtualDisplayRuntimeTrackingClearOutcome(lowerResult.runtimeTrackingClearOutcome),
            runningConfigIDsAfterCommand: lowerResult.runningConfigIDsAfterCommand,
            managedDisplaysAfterCommand: lowerResult.managedDisplaysAfterCommand.map(DisplayRuntimeManagedVirtualDisplay.init)
        )
    }
}

private extension DisplayRuntimeManagedVirtualDisplay {
    init(_ display: ManagedVirtualDisplayRuntimeSnapshot) {
        self.init(
            configID: display.configId,
            serialNumber: display.serialNum,
            displayID: display.displayID,
            isLiveRuntime: display.isLiveRuntime
        )
    }
}

private extension DisplayRuntimeVirtualDisplayCreateConfigEvidence {
    init(_ evidence: VirtualDisplayCommandConfigEvidence) {
        self.init(
            id: evidence.id,
            serialNumber: evidence.serialNumber,
            desiredEnabled: evidence.desiredEnabled,
            physicalWidthMillimeters: evidence.physicalWidthMillimeters,
            physicalHeightMillimeters: evidence.physicalHeightMillimeters,
            modeCount: evidence.modeCount,
            maximumPixelWidth: evidence.maximumPixelWidth,
            maximumPixelHeight: evidence.maximumPixelHeight
        )
    }
}

private extension DisplayRuntimePersistenceOutcome {
    init(_ outcome: VirtualDisplayCommandPersistenceOutcome) {
        switch outcome {
        case .notAttempted:
            self = .notAttempted
        case .saved:
            self = .saved
        case .failed:
            self = .failed
        case .rolledBack:
            self = .rolledBack
        case .rollbackFailed:
            self = .rollbackFailed
        }
    }
}

private extension DisplayRuntimeVirtualDisplayCommandOutcome {
    init(_ outcome: VirtualDisplayCommandRuntimeOutcome) {
        switch outcome {
        case .notAttempted:
            self = .notAttempted
        case .succeeded:
            self = .succeeded
        case .failed:
            self = .failed
        }
    }
}

private extension DisplayRuntimeVirtualDisplayRuntimeTrackingClearOutcome {
    init(_ outcome: VirtualDisplayRuntimeTrackingClearOutcome) {
        switch outcome {
        case .notAttempted:
            self = .notAttempted
        case .cleared:
            self = .cleared
        case .failed:
            self = .failed
        }
    }
}

private extension DisplayRuntimeVirtualDisplayConfigEditDTO {
    init(config: VirtualDisplayConfig) {
        let maxPixels = config.maxPixelDimensions
        self.init(
            id: config.id,
            displayName: config.displayName,
            serialNumber: config.serialNum,
            desiredEnabled: config.desiredEnabled,
            physicalWidthMillimeters: UInt32(clamping: config.physicalWidth),
            physicalHeightMillimeters: UInt32(clamping: config.physicalHeight),
            modes: config.modes.map {
                .init(
                    width: $0.width,
                    height: $0.height,
                    refreshRate: $0.refreshRate,
                    enableHiDPI: $0.enableHiDPI
                )
            },
            maximumPixelWidth: maxPixels.width,
            maximumPixelHeight: maxPixels.height
        )
    }
}

private enum DisplayRuntimeAdapterError: LocalizedError {
    case adapterUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .adapterUnavailable(let reason):
            reason
        }
    }
}

@MainActor
package final class DisplayRuntimeObservabilityAdapter: DisplayRuntimeObservabilityRecording {
    private weak var observability: ObservabilityCenter?

    package init(observability: ObservabilityCenter) {
        self.observability = observability
    }

    package func record(_ event: DisplayRuntimeObservabilityEvent) async {
        await observability?.record(
            ObservabilityEvent(
                severity: ObservabilitySeverity(event.severity),
                subsystem: ObservabilityDomain(event.domain),
                operation: event.operation,
                message: event.message,
                metadata: event.metadata,
                deduplicationKey: event.deduplicationKey
            )
        )
    }

    package func refreshSnapshot(reason: DisplayRuntimeObservabilityRefreshReason) async {
        await observability?.refreshSnapshot(reason: SnapshotRefreshReason(reason))
    }
}

private extension ScreenCaptureCatalogRefreshIntent {
    init(_ intent: DisplayRuntimeCatalogRefreshIntent) {
        switch intent {
        case .permissionChanged:
            self = .permissionChanged
        case .topologyChanged:
            self = .topologyChanged
        case .serviceBecameRunning:
            self = .serviceBecameRunning
        case .userForcedRefresh:
            self = .userForcedRefresh
        }
    }
}

private extension DisplayRuntimeCatalogRefreshResult {
    init(_ result: ScreenCaptureCatalogRefreshResult) {
        switch result {
        case .reloadedSnapshot:
            self = .reloadedSnapshot
        case .reusedSnapshot:
            self = .reusedSnapshot
        case .clearedSnapshot:
            self = .clearedSnapshot
        case .failed:
            self = .failed
        }
    }
}

private extension ObservabilitySeverity {
    init(_ severity: DisplayRuntimeObservabilitySeverity) {
        switch severity {
        case .info:
            self = .info
        case .warning:
            self = .warning
        }
    }
}

private extension ObservabilityDomain {
    init(_ domain: DisplayRuntimeObservabilityDomain) {
        switch domain {
        case .screenCatalog:
            self = .screenCatalog
        case .displayRuntime:
            self = .displayRuntime
        }
    }
}

private extension SnapshotRefreshReason {
    init(_ reason: DisplayRuntimeObservabilityRefreshReason) {
        switch reason {
        case .screenCatalogStateChanged:
            self = .screenCatalogStateChanged
        case .displayRuntimeTransactionChanged:
            self = .displayRuntimeTransactionChanged
        }
    }
}

private extension DisplayRuntimeSharingLifecycle {
    init(state: WebServiceLifecycleState) {
        switch state {
        case .stopped:
            self.init(
                phase: .stopped,
                requestedPort: nil,
                boundPort: nil,
                failureReason: nil,
                hasFailureMessage: false
            )
        case .starting(let requestedPort):
            self.init(
                phase: .starting,
                requestedPort: requestedPort,
                boundPort: nil,
                failureReason: nil,
                hasFailureMessage: false
            )
        case .running(let binding):
            self.init(
                phase: .running,
                requestedPort: binding.requestedPort,
                boundPort: binding.boundPort,
                failureReason: nil,
                hasFailureMessage: false
            )
        case .stopping:
            self.init(
                phase: .stopping,
                requestedPort: nil,
                boundPort: nil,
                failureReason: nil,
                hasFailureMessage: false
            )
        case .failed(let failure):
            self.init(
                phase: .failed,
                requestedPort: failure.requestedPort,
                boundPort: nil,
                failureReason: failure.runtimeFailureReason,
                hasFailureMessage: true
            )
        }
    }
}

private extension WebServiceStartFailure {
    var requestedPort: UInt16? {
        switch self {
        case .invalidPort:
            nil
        case .portInUse(let port), .permissionDenied(let port), .timedOut(let port), .listenerFailed(let port, _):
            port
        }
    }

    var runtimeFailureReason: String {
        switch self {
        case .invalidPort:
            "invalid_port"
        case .portInUse:
            "port_in_use"
        case .permissionDenied:
            "permission_denied"
        case .timedOut:
            "timed_out"
        case .listenerFailed:
            "listener_failed"
        }
    }
}
