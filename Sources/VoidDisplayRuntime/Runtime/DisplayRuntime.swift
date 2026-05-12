import Foundation

@MainActor
package final class DisplayRuntime {
    private let catalogProvider: (any DisplayRuntimeCatalogProviding)?
    private let captureProvider: (any DisplayRuntimeCaptureProviding)?
    private let sharingProvider: (any DisplayRuntimeSharingProviding)?
    private let virtualDisplayProvider: (any DisplayRuntimeVirtualDisplayProviding)?

    package init(
        catalogProvider: (any DisplayRuntimeCatalogProviding)? = nil,
        captureProvider: (any DisplayRuntimeCaptureProviding)? = nil,
        sharingProvider: (any DisplayRuntimeSharingProviding)? = nil,
        virtualDisplayProvider: (any DisplayRuntimeVirtualDisplayProviding)? = nil
    ) {
        self.catalogProvider = catalogProvider
        self.captureProvider = captureProvider
        self.sharingProvider = sharingProvider
        self.virtualDisplayProvider = virtualDisplayProvider
    }

    package func makeSnapshot() -> DisplayRuntimeSnapshot {
        let catalog = catalogProvider?.makeCatalogSnapshot() ?? .empty
        let capture = captureProvider?.makeCaptureSnapshot() ?? .empty
        let sharing = sharingProvider?.makeSharingSnapshot() ?? .empty
        let virtualDisplay = virtualDisplayProvider?.makeVirtualDisplaySnapshot() ?? .empty
        return DisplayRuntimeSnapshot(
            surfaces: DisplaySurfaceGraphBuilder.makeSurfaces(
                catalog: catalog,
                capture: capture,
                sharing: sharing,
                virtualDisplay: virtualDisplay
            ),
            catalog: catalog,
            capture: capture,
            sharing: sharing,
            virtualDisplay: virtualDisplay
        )
    }
}

private nonisolated enum DisplaySurfaceGraphBuilder {
    private struct MutableSurface {
        let identity: DisplaySurfaceIdentity
        let kind: DisplaySurfaceKind
        var currentDisplayID: DisplayRuntimeDisplayID?
        var isAuxiliary: Bool
        var catalog: DisplayRuntimeCatalogSurfaceState?
        var capture: DisplayRuntimeCaptureSurfaceState?
        var sharing: DisplayRuntimeSharingSurfaceState?
        var managedVirtualDisplay: DisplayRuntimeManagedVirtualDisplaySurfaceState?

        func makeSurface() -> DisplaySurface {
            DisplaySurface(
                identity: identity,
                kind: kind,
                currentDisplayID: currentDisplayID,
                isAuxiliary: isAuxiliary,
                catalog: catalog,
                capture: capture,
                sharing: sharing,
                managedVirtualDisplay: managedVirtualDisplay
            )
        }
    }

    static func makeSurfaces(
        catalog: DisplayRuntimeCatalogSnapshot,
        capture: DisplayRuntimeCaptureSnapshot,
        sharing: DisplayRuntimeSharingSnapshot,
        virtualDisplay: DisplayRuntimeVirtualDisplaySnapshot
    ) -> [DisplaySurface] {
        let managedByConfigID = firstValuesByKey(
            virtualDisplay.managedDisplays,
            key: \.configID
        )
        let configsByID = firstValuesByKey(
            virtualDisplay.configs,
            key: \.id
        )
        let runningConfigIDs = Set(virtualDisplay.runningConfigIDs)
        let rebuildingConfigIDs = Set(virtualDisplay.rebuildingConfigIDs)
        let recentlyAppliedConfigIDs = Set(virtualDisplay.recentlyAppliedConfigIDs)
        let rebuildFailureConfigIDs = Set(virtualDisplay.rebuildFailureConfigIDs)
        let restoreFailureConfigIDs = Set(virtualDisplay.restoreFailureConfigIDs)

        var surfaces: [DisplaySurfaceIdentity: MutableSurface] = [:]
        for configID in Set(configsByID.keys).union(managedByConfigID.keys) {
            let identity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
            let config = configsByID[configID]
            let managed = managedByConfigID[configID]
            let maximumPixelDimensions = config.flatMap(maximumPixelDimensions)
            surfaces[identity] = MutableSurface(
                identity: identity,
                kind: .managedVirtualDisplay,
                currentDisplayID: managed?.displayID,
                isAuxiliary: false,
                catalog: nil,
                capture: nil,
                sharing: nil,
                managedVirtualDisplay: .init(
                    configID: configID,
                    serialNumber: config?.serialNumber ?? managed?.serialNumber,
                    desiredEnabled: config?.desiredEnabled,
                    isRunning: runningConfigIDs.contains(configID),
                    isLiveRuntime: managed?.isLiveRuntime ?? false,
                    isRebuilding: rebuildingConfigIDs.contains(configID),
                    hasRecentApplySuccess: recentlyAppliedConfigIDs.contains(configID),
                    hasRebuildFailure: rebuildFailureConfigIDs.contains(configID),
                    hasRestoreFailure: restoreFailureConfigIDs.contains(configID),
                    modeCount: config?.modes.count,
                    maximumPixelWidth: maximumPixelDimensions?.width,
                    maximumPixelHeight: maximumPixelDimensions?.height
                )
            )
        }

        var identityByDisplayID: [DisplayRuntimeDisplayID: DisplaySurfaceIdentity] = [:]
        for managed in virtualDisplay.managedDisplays.sorted(by: managedDisplaySort) {
            identityByDisplayID[managed.displayID] = identityByDisplayID[managed.displayID]
                ?? DisplaySurfaceIdentity.managedVirtualDisplay(configID: managed.configID)
        }

        func ensurePhysicalSurface(displayID: DisplayRuntimeDisplayID) -> DisplaySurfaceIdentity {
            let identity = DisplaySurfaceIdentity.physicalDisplay(displayID: displayID)
            if surfaces[identity] == nil {
                surfaces[identity] = MutableSurface(
                    identity: identity,
                    kind: .physicalDisplay,
                    currentDisplayID: displayID,
                    isAuxiliary: true,
                    catalog: nil,
                    capture: nil,
                    sharing: nil,
                    managedVirtualDisplay: nil
                )
            }
            identityByDisplayID[displayID] = identity
            return identity
        }

        func identity(for displayID: DisplayRuntimeDisplayID) -> DisplaySurfaceIdentity {
            identityByDisplayID[displayID] ?? ensurePhysicalSurface(displayID: displayID)
        }

        let topologyByDisplayID = firstValuesByKey(
            catalog.topologySignature,
            key: \.displayID
        )
        for display in catalog.loadedDisplays {
            let surfaceIdentity = identity(for: display.displayID)
            var surface = surfaces[surfaceIdentity]!
            let topology = topologyByDisplayID[display.displayID]
            surface.catalog = DisplayRuntimeCatalogSurfaceState(
                displayID: display.displayID,
                isVisible: true,
                isMain: topology?.isMain,
                pixelWidth: topology?.pixelWidth ?? display.pixelWidth,
                pixelHeight: topology?.pixelHeight ?? display.pixelHeight,
                refreshRateMilliHertz: topology?.refreshRateMilliHertz,
                mirrorsDisplayID: topology?.mirrorsDisplayID
            )
            if surface.currentDisplayID == nil {
                surface.currentDisplayID = display.displayID
            }
            surfaces[surfaceIdentity] = surface
        }

        for topology in catalog.topologySignature where catalog.loadedDisplays.allSatisfy({ $0.displayID != topology.displayID }) {
            let surfaceIdentity = identity(for: topology.displayID)
            var surface = surfaces[surfaceIdentity]!
            surface.catalog = DisplayRuntimeCatalogSurfaceState(
                displayID: topology.displayID,
                isVisible: true,
                isMain: topology.isMain,
                pixelWidth: topology.pixelWidth,
                pixelHeight: topology.pixelHeight,
                refreshRateMilliHertz: topology.refreshRateMilliHertz,
                mirrorsDisplayID: topology.mirrorsDisplayID
            )
            if surface.currentDisplayID == nil {
                surface.currentDisplayID = topology.displayID
            }
            surfaces[surfaceIdentity] = surface
        }

        let captureSessionsByDisplayID = Dictionary(grouping: capture.sessions, by: \.displayID)
        for displayID in Set(capture.startingDisplayIDs).union(captureSessionsByDisplayID.keys) {
            let surfaceIdentity = identity(for: displayID)
            var surface = surfaces[surfaceIdentity]!
            let sessions = captureSessionsByDisplayID[displayID] ?? []
            surface.capture = DisplayRuntimeCaptureSurfaceState(
                displayID: displayID,
                isStarting: capture.startingDisplayIDs.contains(displayID),
                sessionIDs: sessions.map(\.id),
                capturesCursor: sessions.contains(where: \.capturesCursor),
                receivedFrameCount: sessions.reduce(0) { $0 + $1.metrics.receivedFrameCount }
            )
            if surface.currentDisplayID == nil {
                surface.currentDisplayID = displayID
            }
            surfaces[surfaceIdentity] = surface
        }

        var viewerCounts: [DisplayRuntimeDisplayID: Int] = [:]
        for clientCount in sharing.sharingClientCounts {
            viewerCounts[clientCount.displayID, default: 0] += clientCount.count
        }
        let routeDisplayIDs = Set(sharing.routes.map(\.displayID))
        let sharingDisplayIDs = Set(sharing.activeSharingDisplayIDs)
            .union(sharing.startingDisplayIDs)
            .union(viewerCounts.keys)
            .union(routeDisplayIDs)
        for displayID in sharingDisplayIDs {
            let surfaceIdentity = identity(for: displayID)
            var surface = surfaces[surfaceIdentity]!
            surface.sharing = DisplayRuntimeSharingSurfaceState(
                displayID: displayID,
                isStarting: sharing.startingDisplayIDs.contains(displayID),
                isActive: sharing.activeSharingDisplayIDs.contains(displayID),
                viewerCount: viewerCounts[displayID] ?? 0,
                hasRoute: sharing.routes.contains { $0.displayID == displayID && $0.hasConcreteRoute }
            )
            if surface.currentDisplayID == nil {
                surface.currentDisplayID = displayID
            }
            surfaces[surfaceIdentity] = surface
        }

        return surfaces.values
            .map { $0.makeSurface() }
            .sorted(by: surfaceSort)
    }

    private static func firstValuesByKey<Value, Key: Hashable>(
        _ values: [Value],
        key: (Value) -> Key
    ) -> [Key: Value] {
        var result: [Key: Value] = [:]
        for value in values {
            result[key(value)] = result[key(value)] ?? value
        }
        return result
    }

    private static func managedDisplaySort(
        lhs: DisplayRuntimeManagedVirtualDisplay,
        rhs: DisplayRuntimeManagedVirtualDisplay
    ) -> Bool {
        if lhs.displayID != rhs.displayID { return lhs.displayID < rhs.displayID }
        return lhs.configID.uuidString < rhs.configID.uuidString
    }

    private static func surfaceSort(lhs: DisplaySurface, rhs: DisplaySurface) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        if lhs.identity.stableID != rhs.identity.stableID {
            return lhs.identity.stableID < rhs.identity.stableID
        }
        return (lhs.currentDisplayID ?? 0) < (rhs.currentDisplayID ?? 0)
    }

    private static func maximumPixelDimensions(
        for config: DisplayRuntimeVirtualDisplayConfig
    ) -> (width: Int, height: Int)? {
        guard let maxMode = config.modes.max(by: { pixelArea($0) < pixelArea($1) }) else {
            return nil
        }
        let scale = config.modes.contains(where: \.enableHiDPI) ? 2 : 1
        let (width, widthOverflow) = maxMode.width.multipliedReportingOverflow(by: scale)
        let (height, heightOverflow) = maxMode.height.multipliedReportingOverflow(by: scale)
        guard !widthOverflow, !heightOverflow else { return nil }
        return (width, height)
    }

    private static func pixelArea(_ mode: DisplayRuntimeVirtualDisplayMode) -> Int {
        let (area, overflow) = mode.width.multipliedReportingOverflow(by: mode.height)
        guard !overflow else { return Int.max }
        return max(0, area)
    }
}
