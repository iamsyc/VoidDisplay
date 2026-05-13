import Foundation

@MainActor
extension DisplayRuntime {
    func makeLifecycleAffectedScope(
        kind: DisplayRuntimeTransactionKind,
        configID: UUID,
        snapshot: DisplayRuntimeSnapshot,
        enablePreflight: DisplayRuntimeVirtualDisplayEnablePreflight?
    ) -> (surfaces: [DisplayRuntimeAffectedSurface], scopeEscalationReason: DisplayRuntimeScopeEscalationReason?) {
        switch kind {
        case .virtualDisplayRebuild, .virtualDisplayEditRebuild, .virtualDisplayCreate, .virtualDisplayDelete:
            return (makeAffectedSurfaces(configID: configID, snapshot: snapshot), nil)
        case .virtualDisplayEnable:
            return makeEnableAffectedScope(
                configID: configID,
                snapshot: snapshot,
                preflight: enablePreflight
            )
        case .virtualDisplayDisable:
            let surfaces = makeAffectedSurfaces(configID: configID, snapshot: snapshot)
            let hasPeer = surfaces.contains { $0.configID != configID }
            return (surfaces, hasPeer ? .managedMainPolicyRisk : nil)
        }
    }

    func makeAffectedSurfaces(
        configID: UUID,
        snapshot: DisplayRuntimeSnapshot
    ) -> [DisplayRuntimeAffectedSurface] {
        let requestedIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        guard let requestedSurface = snapshot.surfaces.first(where: { $0.identity == requestedIdentity }) else {
            return []
        }

        let managedDisplaysByConfigID = firstValuesByKey(snapshot.virtualDisplay.managedDisplays, key: \.configID)
        let runningConfigIDs = Set(snapshot.virtualDisplay.runningConfigIDs)
        let runningManagedDisplays = managedDisplaysByConfigID.values.filter {
            runningConfigIDs.contains($0.configID)
        }.sorted {
            $0.configID.uuidString < $1.configID.uuidString
        }
        let requestedIsRunning = runningConfigIDs.contains(configID)
        let requestedMainState = requestedSurface.catalog?.isMain
        let shouldEscalateToFleet = runningManagedDisplays.count >= 2
            && requestedIsRunning
            && requestedMainState != false

        if shouldEscalateToFleet {
            return runningManagedDisplays.map { managed in
                let identity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: managed.configID)
                let surface = snapshot.surfaces.first { $0.identity == identity }
                return makeAffectedSurface(
                    identity: identity,
                    configID: managed.configID,
                    surface: surface,
                    snapshot: snapshot,
                    fallbackManagedDisplay: managed,
                    reason: managed.configID == configID ? .requestedConfig : .managedMainFleetPeer
                )
            }
        }

        return [
            makeAffectedSurface(
                identity: requestedIdentity,
                configID: configID,
                surface: requestedSurface,
                snapshot: snapshot,
                fallbackManagedDisplay: managedDisplaysByConfigID[configID],
                reason: .requestedConfig
            )
        ]
    }

    private func makeEnableAffectedScope(
        configID: UUID,
        snapshot: DisplayRuntimeSnapshot,
        preflight: DisplayRuntimeVirtualDisplayEnablePreflight?
    ) -> (surfaces: [DisplayRuntimeAffectedSurface], scopeEscalationReason: DisplayRuntimeScopeEscalationReason?) {
        let targetIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        guard let targetSurface = snapshot.surfaces.first(where: { $0.identity == targetIdentity }) else {
            return ([], nil)
        }

        let targetOnlyProven = preflight?.mayPerformFleetRebuild == false
            && preflight?.requiresFleetQuiesce == false
        guard !targetOnlyProven else {
            return ([
                makeAffectedSurface(
                    identity: targetIdentity,
                    configID: configID,
                    surface: targetSurface,
                    snapshot: snapshot,
                    reason: .requestedConfig
                )
            ], nil)
        }

        let runningConfigIDs = Set(snapshot.virtualDisplay.runningConfigIDs)
        let runningManagedDisplays = firstValuesByKey(snapshot.virtualDisplay.managedDisplays, key: \.configID)
            .values
            .filter { runningConfigIDs.contains($0.configID) }
            .sorted { $0.configID.uuidString < $1.configID.uuidString }
        var surfaces: [DisplayRuntimeAffectedSurface] = [
            makeAffectedSurface(
                identity: targetIdentity,
                configID: configID,
                surface: targetSurface,
                snapshot: snapshot,
                reason: .requestedConfig
            )
        ]
        for managed in runningManagedDisplays where managed.configID != configID {
            let identity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: managed.configID)
            let surface = snapshot.surfaces.first { $0.identity == identity }
            surfaces.append(
                makeAffectedSurface(
                    identity: identity,
                    configID: managed.configID,
                    surface: surface,
                    snapshot: snapshot,
                    fallbackManagedDisplay: managed,
                    reason: .enableFleetRiskPeer
                )
            )
        }
        return (surfaces, .scopeEscalatedEnableMayPerformFleetRebuild)
    }

    private func makeAffectedSurface(
        identity: DisplaySurfaceIdentity,
        configID: UUID,
        surface: DisplaySurface?,
        snapshot: DisplayRuntimeSnapshot,
        fallbackManagedDisplay: DisplayRuntimeManagedVirtualDisplay? = nil,
        reason: DisplayRuntimeAffectedSurfaceReason
    ) -> DisplayRuntimeAffectedSurface {
        let configsByID = firstValuesByKey(snapshot.virtualDisplay.configs, key: \.id)
        return DisplayRuntimeAffectedSurface(
            identity: identity,
            configID: configID,
            preDisplayID: surface?.currentDisplayID ?? fallbackManagedDisplay?.displayID,
            serialNumber: configsByID[configID]?.serialNumber ?? fallbackManagedDisplay?.serialNumber,
            reason: reason
        )
    }

    private func firstValuesByKey<Value, Key: Hashable>(
        _ values: [Value],
        key: (Value) -> Key
    ) -> [Key: Value] {
        var result: [Key: Value] = [:]
        for value in values {
            result[key(value)] = result[key(value)] ?? value
        }
        return result
    }
}
