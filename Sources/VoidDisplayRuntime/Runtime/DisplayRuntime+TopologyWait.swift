import Foundation

@MainActor
extension DisplayRuntime {
    @discardableResult
    func refreshCatalogTopologyForTransaction() async -> DisplayRuntimeCatalogRefreshResult {
        guard let catalogCommander else { return .failed }
        let result = await catalogCommander.submitRefresh(intent: .topologyChanged, ownerScope: nil)
        await observabilityRecorder?.refreshSnapshot(reason: .screenCatalogStateChanged)
        return result
    }

    func waitForPostCommandTopology(
        kind: DisplayRuntimeTransactionKind,
        affectedSurfaces: [DisplayRuntimeAffectedSurface]
    ) async -> DisplayRuntimeTopologyStabilityResult {
        var samples: [DisplayRuntimeTopologyStabilitySample] = []
        var previousStableSample: DisplayRuntimeTopologyStabilitySample?
        var stableSampleCount = 0

        for index in 0..<topologyWaitPolicy.maximumSampleCount {
            if index > 0 && topologyWaitPolicy.sampleIntervalNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: topologyWaitPolicy.sampleIntervalNanoseconds)
            }

            let refreshResult = await refreshCatalogTopologyForTransaction()
            let snapshot = makeSnapshot()
            let sample = DisplayRuntimeTopologyStabilitySample(snapshot: snapshot)
            samples.append(sample)

            if catalogPermissionUnavailable(snapshot.catalog) {
                return topologyResult(
                    status: .unprovableDueToPermission,
                    samples: samples,
                    failureReason: "screen_capture_permission_unavailable"
                )
            }
            if refreshResult == .failed {
                return topologyResult(
                    status: .failed,
                    samples: samples,
                    failureReason: "catalog_refresh_failed"
                )
            }

            if affectedSurfacesResolveToVisibleDisplayIDs(
                affectedSurfaces,
                kind: kind,
                snapshot: snapshot
            ) {
                if previousStableSample == sample {
                    stableSampleCount += 1
                } else {
                    previousStableSample = sample
                    stableSampleCount = 1
                }
                if stableSampleCount >= topologyWaitPolicy.requiredStableSampleCount {
                    return topologyResult(status: .stable, samples: samples, failureReason: nil)
                }
            } else {
                previousStableSample = nil
                stableSampleCount = 0
            }
        }

        return topologyResult(
            status: .timedOut,
            samples: samples,
            failureReason: "topology_stability_timed_out"
        )
    }

    private func topologyResult(
        status: DisplayRuntimeTopologyStabilityStatus,
        samples: [DisplayRuntimeTopologyStabilitySample],
        failureReason: String?
    ) -> DisplayRuntimeTopologyStabilityResult {
        DisplayRuntimeTopologyStabilityResult(
            status: status,
            sampleCount: samples.count,
            failureReason: failureReason,
            lastSample: samples.last
        )
    }

    private func catalogPermissionUnavailable(_ catalog: DisplayRuntimeCatalogSnapshot) -> Bool {
        catalog.hasScreenCapturePermission == false || catalog.lastPreflightPermission == false
    }

    private func affectedSurfacesResolveToVisibleDisplayIDs(
        _ affectedSurfaces: [DisplayRuntimeAffectedSurface],
        kind: DisplayRuntimeTransactionKind,
        snapshot: DisplayRuntimeSnapshot
    ) -> Bool {
        let surfacesToResolve: [DisplayRuntimeAffectedSurface]
        switch kind {
        case .virtualDisplayDisable, .virtualDisplayDelete:
            surfacesToResolve = affectedSurfaces.filter { $0.reason != .requestedConfig }
        case .virtualDisplayRebuild, .virtualDisplayEnable, .virtualDisplayEditRebuild, .virtualDisplayCreate,
             .virtualDisplayStartupRestore:
            surfacesToResolve = affectedSurfaces
        }
        guard !surfacesToResolve.isEmpty else {
            return kind == .virtualDisplayDisable || kind == .virtualDisplayDelete
        }
        let visibleDisplayIDs = Set(snapshot.catalog.loadedDisplays.map(\.displayID))
        return surfacesToResolve.allSatisfy { affectedSurface in
            guard let surface = snapshot.surfaces.first(where: { $0.identity == affectedSurface.identity }),
                  let displayID = surface.currentDisplayID,
                  surface.managedVirtualDisplay?.isRunning != false
            else {
                return false
            }
            return visibleDisplayIDs.contains(displayID)
        }
    }
}
