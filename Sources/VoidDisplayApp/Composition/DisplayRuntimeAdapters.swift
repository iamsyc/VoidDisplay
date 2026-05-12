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
