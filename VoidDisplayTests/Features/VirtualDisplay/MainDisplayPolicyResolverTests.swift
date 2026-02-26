import CoreGraphics
import Foundation
import Testing
@testable import VoidDisplay

@MainActor
@Suite(.serialized)
struct MainDisplayPolicyResolverTests {
    @Test
    func resolveWithoutSnapshotDisablesPolicy() {
        let state = ResolverState(
            configs: [makeConfig(serial: 1, enabled: true)],
            runtimeDisplayIDs: [:]
        )
        let resolver = makeResolver(state: state)

        let resolution = resolver.resolveMainDisplayPolicy(snapshot: nil, emitLog: false)

        #expect(resolution.applies == false)
        #expect(resolution.source == .policyDisabledNoSnapshot)
        #expect(resolution.targetConfigID == nil)
    }

    @Test
    func resolveWithPhysicalDisplayDisablesPolicy() {
        let state = ResolverState(
            configs: [makeConfig(serial: 1, enabled: true), makeConfig(serial: 2, enabled: true)],
            runtimeDisplayIDs: [:]
        )
        let resolver = makeResolver(state: state)
        let snapshot = DisplayTopologySnapshot(
            mainDisplayID: 100,
            displays: [
                displayInfo(id: 100, serial: 900, managed: false),
                displayInfo(id: 101, serial: 1, managed: true),
                displayInfo(id: 102, serial: 2, managed: true)
            ]
        )

        let resolution = resolver.resolveMainDisplayPolicy(snapshot: snapshot, emitLog: false)

        #expect(resolution.applies == false)
        #expect(resolution.source == .policyDisabledPhysicalPresent)
    }

    @Test
    func resolveWithTooFewEnabledDisablesPolicy() {
        let state = ResolverState(
            configs: [makeConfig(serial: 1, enabled: true), makeConfig(serial: 2, enabled: false)],
            runtimeDisplayIDs: [:]
        )
        let resolver = makeResolver(state: state)
        let snapshot = DisplayTopologySnapshot(
            mainDisplayID: 101,
            displays: [
                displayInfo(id: 101, serial: 1, managed: true),
                displayInfo(id: 102, serial: 2, managed: true)
            ]
        )

        let resolution = resolver.resolveMainDisplayPolicy(snapshot: snapshot, emitLog: false)

        #expect(resolution.applies == false)
        #expect(resolution.source == .policyDisabledTooFewEnabled)
    }

    @Test
    func resolveListOrderSelectsFirstEnabledConfig() {
        let configA = makeConfig(serial: 1, enabled: true)
        let configB = makeConfig(serial: 2, enabled: true)
        let state = ResolverState(
            configs: [configA, configB],
            runtimeDisplayIDs: [configA.id: 201, configB.id: 202]
        )
        let resolver = makeResolver(state: state)
        let snapshot = DisplayTopologySnapshot(
            mainDisplayID: 202,
            displays: [
                displayInfo(id: 201, serial: 1, managed: true),
                displayInfo(id: 202, serial: 2, managed: true)
            ]
        )

        let resolution = resolver.resolveMainDisplayPolicy(snapshot: snapshot, emitLog: false)

        #expect(resolution.applies)
        #expect(resolution.source == .listOrder)
        #expect(resolution.targetConfigID == configA.id)
        #expect(resolution.targetDisplayID == 201)
        #expect(resolution.preferredMainDisplayID == 201)
    }

    @Test
    func reconcileSkipsWhenTargetDisplayIDMissing() async throws {
        let configA = makeConfig(serial: 1, enabled: true)
        let configB = makeConfig(serial: 2, enabled: true)
        let state = ResolverState(
            configs: [configA, configB],
            runtimeDisplayIDs: [:]
        )
        let resolver = makeResolver(state: state)
        let snapshot = DisplayTopologySnapshot(
            mainDisplayID: 202,
            displays: [
                displayInfo(id: 201, serial: 1, managed: true),
                displayInfo(id: 202, serial: 2, managed: true)
            ]
        )

        var ensureCalled = false
        try await resolver.reconcileMainDisplayPolicyIfNeeded(snapshot: snapshot) { _ in
            ensureCalled = true
        }

        #expect(ensureCalled == false)
    }

    @Test
    func reconcileInvokesEnsureHealthyTopologyWhenRepairNeeded() async throws {
        let configA = makeConfig(serial: 1, enabled: true)
        let configB = makeConfig(serial: 2, enabled: true)
        let state = ResolverState(
            configs: [configA, configB],
            runtimeDisplayIDs: [configA.id: 301, configB.id: 302]
        )
        let resolver = makeResolver(state: state)
        let collapsed = DisplayTopologySnapshot(
            mainDisplayID: 302,
            displays: [
                displayInfo(id: 301, serial: 1, managed: true, inMirrorSet: true, mirrorMasterID: 302),
                displayInfo(id: 302, serial: 2, managed: true, inMirrorSet: true, mirrorMasterID: nil)
            ]
        )

        var ensureCallCount = 0
        var receivedPreferredMain: CGDirectDisplayID?
        try await resolver.reconcileMainDisplayPolicyIfNeeded(snapshot: collapsed) { preferredMain in
            ensureCallCount += 1
            receivedPreferredMain = preferredMain
        }

        #expect(ensureCallCount == 1)
        #expect(receivedPreferredMain == 301)
    }

    @Test
    func aggressiveRecoveryPendingTrackingByConfigAndSerial() {
        let configA = makeConfig(serial: 11, enabled: true)
        let configB = makeConfig(serial: 12, enabled: true)
        let state = ResolverState(
            configs: [configA, configB],
            runtimeDisplayIDs: [:]
        )
        let resolver = makeResolver(state: state)

        resolver.markAggressiveRecoveryPending(configId: configA.id)
        #expect(resolver.isAggressiveRecoveryPending(configId: configA.id))

        resolver.markAggressiveRecoveryPendingForSerial(configB.serialNum)
        #expect(resolver.isAggressiveRecoveryPending(configId: configB.id))

        resolver.clearAggressiveRecoveryPendingForSerial(configA.serialNum)
        #expect(resolver.isAggressiveRecoveryPending(configId: configA.id) == false)

        resolver.resetAll()
        #expect(resolver.isAggressiveRecoveryPending(configId: configB.id) == false)
    }
}

@MainActor
private final class ResolverState {
    var configs: [VirtualDisplayConfig]
    var runtimeDisplayIDs: [UUID: CGDirectDisplayID]

    init(configs: [VirtualDisplayConfig], runtimeDisplayIDs: [UUID: CGDirectDisplayID]) {
        self.configs = configs
        self.runtimeDisplayIDs = runtimeDisplayIDs
    }
}

private extension MainDisplayPolicyResolverTests {
    func makeResolver(state: ResolverState) -> MainDisplayPolicyResolver {
        MainDisplayPolicyResolver(
            enabledDesiredConfigsProvider: {
                state.configs.filter(\.desiredEnabled)
            },
            runtimeDisplayIDProvider: { configId in
                state.runtimeDisplayIDs[configId]
            },
            allConfigsProvider: {
                state.configs
            }
        )
    }

    func makeConfig(serial: UInt32, enabled: Bool) -> VirtualDisplayConfig {
        VirtualDisplayConfig(
            id: UUID(),
            displayName: "Managed \(serial)",
            serialNum: serial,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: enabled
        )
    }

    func displayInfo(
        id: CGDirectDisplayID,
        serial: UInt32,
        managed: Bool,
        inMirrorSet: Bool = false,
        mirrorMasterID: CGDirectDisplayID? = nil
    ) -> DisplayTopologySnapshot.DisplayInfo {
        DisplayTopologySnapshot.DisplayInfo(
            id: id,
            serialNumber: serial,
            isManagedVirtualDisplay: managed,
            isActive: true,
            isInMirrorSet: inMirrorSet,
            mirrorMasterDisplayID: mirrorMasterID,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
    }
}
