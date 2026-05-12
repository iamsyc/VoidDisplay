import VoidDisplayCapture
import VoidDisplayFoundation
import VoidDisplayRuntime
import VoidDisplaySharing
import VoidDisplayVirtualDisplay
import Foundation

@MainActor
package final class DisplayRuntimeCatalogAdapter: DisplayRuntimeCatalogProviding {
    private weak var store: ScreenCaptureCatalogStore?

    package init(store: ScreenCaptureCatalogStore) {
        self.store = store
    }

    package func makeCatalogSnapshot() -> DisplayRuntimeCatalogSnapshot {
        guard let store else { return .empty }
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
}

@MainActor
package final class DisplayRuntimeCaptureAdapter: DisplayRuntimeCaptureProviding {
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
}

@MainActor
package final class DisplayRuntimeSharingAdapter: DisplayRuntimeSharingProviding {
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
}

@MainActor
package final class DisplayRuntimeVirtualDisplayAdapter: DisplayRuntimeVirtualDisplayProviding {
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
