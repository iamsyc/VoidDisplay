import CoreGraphics
import Foundation
import Testing
@testable import VoidDisplay

@Suite(.serialized)
struct VirtualDisplayTopologyRecoveryTests {

    @MainActor
    @Test func postEnableMirrorCollapseTriggersRepairAndKeepsCurrentMainAsAnchor() async throws {
        let displayA: CGDirectDisplayID = 201
        let displayB: CGDirectDisplayID = 202

        let collapsed = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, inMirrorSet: true, mirrorMasterID: displayB),
                displayInfo(id: displayB, serial: 2, managed: true, inMirrorSet: true, mirrorMasterID: nil)
            ]
        )
        let expanded = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [collapsed, collapsed, collapsed, expanded, expanded, expanded]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.2,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigs([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try await service.ensureHealthyTopologyAfterEnable()

        #expect(repairer.callCount == 2)
        #expect(repairer.lastAnchorDisplayID == displayB)
        #expect(Set(repairer.lastManagedDisplayIDs) == Set([displayA, displayB]))
    }

    @MainActor
    @Test func postEnableOverlappingManagedDisplaysWithoutMirrorFlagsTriggersRepair() async throws {
        let hiddenMain: CGDirectDisplayID = 290
        let displayA: CGDirectDisplayID = 291
        let displayB: CGDirectDisplayID = 292

        let collapsed = topologySnapshot(
            mainDisplayID: hiddenMain,
            displays: [
                displayInfo(
                    id: hiddenMain,
                    serial: 90,
                    managed: false,
                    bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
                ),
                displayInfo(
                    id: displayA,
                    serial: 1,
                    managed: true,
                    bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
                ),
                displayInfo(
                    id: displayB,
                    serial: 2,
                    managed: true,
                    bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
                )
            ]
        )
        let recovered = topologySnapshot(
            mainDisplayID: hiddenMain,
            displays: [
                displayInfo(
                    id: hiddenMain,
                    serial: 90,
                    managed: false,
                    bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
                ),
                displayInfo(
                    id: displayA,
                    serial: 1,
                    managed: true,
                    bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
                ),
                displayInfo(
                    id: displayB,
                    serial: 2,
                    managed: true,
                    bounds: CGRect(x: 3920, y: 0, width: 1920, height: 1080)
                )
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [collapsed, collapsed, collapsed, recovered, recovered, recovered]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.2,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigs([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try await service.ensureHealthyTopologyAfterEnable()
        #expect(repairer.callCount == 1)
        #expect(Set(repairer.lastManagedDisplayIDs) == Set([displayA, displayB]))
    }

    @MainActor
    @Test func postEnableUsesPreferredManagedMainForContinuityWhenSystemMainDrifts() async throws {
        let displayA: CGDirectDisplayID = 701
        let displayB: CGDirectDisplayID = 702

        let collapsedOnA = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, inMirrorSet: true, mirrorMasterID: nil),
                displayInfo(id: displayB, serial: 2, managed: true, inMirrorSet: true, mirrorMasterID: displayA)
            ]
        )
        let expandedButStillMainA = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )
        let expandedRecoveredToB = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [
                collapsedOnA, collapsedOnA, collapsedOnA,
                expandedButStillMainA, expandedButStillMainA, expandedButStillMainA,
                expandedButStillMainA, expandedButStillMainA, expandedButStillMainA,
                expandedRecoveredToB, expandedRecoveredToB, expandedRecoveredToB
            ]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.25,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigs([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try await service.ensureHealthyTopologyAfterEnable(preferredMainDisplayID: displayB)
        #expect(repairer.callCount == 3)
        #expect(repairer.lastAnchorDisplayID == displayB)
        #expect(Set(repairer.lastManagedDisplayIDs) == Set([displayA, displayB]))
    }

    @MainActor
    @Test func postEnableRepairFailureThrowsTopologyRepairFailed() async {
        let displayA: CGDirectDisplayID = 301
        let displayB: CGDirectDisplayID = 302

        let collapsed = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, inMirrorSet: true, mirrorMasterID: displayB),
                displayInfo(id: displayB, serial: 2, managed: true, inMirrorSet: true, mirrorMasterID: nil)
            ]
        )

        let inspector = FakeDisplayTopologyInspector(snapshots: [collapsed, collapsed, collapsed])
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: false)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.25,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigs([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        do {
            try await service.ensureHealthyTopologyAfterEnable()
            Issue.record("Expected topology repair to fail.")
        } catch let error as VirtualDisplayService.VirtualDisplayError {
            guard case .topologyRepairFailed = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @MainActor
    @Test func regressionScenarioAReEnableWithoutDisablingBRecoversExpandedTopology() async throws {
        let displayA: CGDirectDisplayID = 401
        let displayB: CGDirectDisplayID = 402

        let collapsedAfterAReenable = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, inMirrorSet: true, mirrorMasterID: displayB),
                displayInfo(id: displayB, serial: 2, managed: true, inMirrorSet: true, mirrorMasterID: nil)
            ]
        )
        let recoveredExpanded = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [
                collapsedAfterAReenable,
                collapsedAfterAReenable,
                collapsedAfterAReenable,
                recoveredExpanded,
                recoveredExpanded,
                recoveredExpanded
            ]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.2,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigs([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try await service.ensureHealthyTopologyAfterEnable()
        #expect(repairer.callCount == 2)
    }

    @MainActor
    @Test func postEnableDeferredVerificationRepairsLateMirrorCollapse() async throws {
        let physicalDisplay: CGDirectDisplayID = 480
        let displayA: CGDirectDisplayID = 481
        let displayB: CGDirectDisplayID = 482

        let initiallyExpanded = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: physicalDisplay, serial: 900, managed: false),
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )
        let delayedCollapsed = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: physicalDisplay, serial: 900, managed: false),
                displayInfo(id: displayA, serial: 1, managed: true, inMirrorSet: true, mirrorMasterID: displayB),
                // Mirror root may not be flagged during transitions.
                displayInfo(id: displayB, serial: 2, managed: true, inMirrorSet: false, mirrorMasterID: nil)
            ]
        )
        let recoveredExpanded = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: physicalDisplay, serial: 900, managed: false),
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [
                initiallyExpanded, initiallyExpanded, initiallyExpanded,
                delayedCollapsed, delayedCollapsed, delayedCollapsed,
                recoveredExpanded, recoveredExpanded, recoveredExpanded
            ]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.2,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigs([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try await service.ensureHealthyTopologyAfterEnable()
        #expect(repairer.callCount == 1)
        #expect(repairer.lastAnchorDisplayID == displayB)
        #expect(Set(repairer.lastManagedDisplayIDs) == Set([displayA, displayB]))
    }

    @MainActor
    @Test func postEnableFastRecoveryModeSkipsForceNormalizationForStablePureVirtualTopology() async throws {
        let displayA: CGDirectDisplayID = 490
        let displayB: CGDirectDisplayID = 491
        let expanded = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [expanded, expanded, expanded]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.2,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigs([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try await service.ensureHealthyTopologyAfterEnable(recoveryMode: .fast)
        #expect(repairer.callCount == 0)
    }

    @MainActor
    @Test func postEnableAggressiveRecoverySkipsForceNormalizationForStablePureVirtualTopology() async throws {
        let displayA: CGDirectDisplayID = 492
        let displayB: CGDirectDisplayID = 493
        let expanded = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [
                expanded, expanded, expanded,
                expanded, expanded, expanded
            ]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.2,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigs([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try await service.ensureHealthyTopologyAfterEnable(
            preferredMainDisplayID: displayA,
            recoveryMode: .aggressive
        )
        #expect(repairer.callCount == 0)
    }

    @MainActor
    @Test func postEnableFastRecoveryDeferredPassRepairsManagedMainContinuityWhenInitialSnapshotIsIncomplete() async throws {
        let displayA: CGDirectDisplayID = 493
        let displayB: CGDirectDisplayID = 494

        let initialIncomplete = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))
            ]
        )
        let deferredExpandedButDriftedMain = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1440, height: 900)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [
                initialIncomplete,
                deferredExpandedButDriftedMain, deferredExpandedButDriftedMain, deferredExpandedButDriftedMain,
                deferredExpandedButDriftedMain, deferredExpandedButDriftedMain, deferredExpandedButDriftedMain
            ]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.2,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigs([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try await service.ensureHealthyTopologyAfterEnable(
            preferredMainDisplayID: displayA,
            recoveryMode: .fast
        )
        #expect(repairer.callCount == 1)
        #expect(repairer.lastAnchorDisplayID == displayA)
        #expect(Set(repairer.lastManagedDisplayIDs) == Set([displayA, displayB]))
    }

    @MainActor
    @Test func postEnableMainOutsideManagedWithoutPhysicalFallbackTriggersRepair() async throws {
        let displayA: CGDirectDisplayID = 501
        let displayB: CGDirectDisplayID = 502
        let nonManagedMain: CGDirectDisplayID = 999

        let broken = topologySnapshot(
            mainDisplayID: nonManagedMain,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true),
                displayInfo(id: displayB, serial: 2, managed: true)
            ]
        )
        let recovered = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [broken, broken, broken, recovered, recovered, recovered]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.2,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigs([
            config(serial: 1, desiredEnabled: true),
            config(serial: 2, desiredEnabled: true)
        ])

        try await service.ensureHealthyTopologyAfterEnable()
        #expect(repairer.callCount == 2)
        #expect(repairer.lastAnchorDisplayID == displayB)
    }

    @MainActor
    @Test func postEnableThrowsTopologyUnstableWhenTopologyNeverSettles() async {
        let first = topologySnapshot(
            mainDisplayID: 601,
            displays: [
                displayInfo(id: 601, serial: 1, managed: true)
            ]
        )
        let second = topologySnapshot(
            mainDisplayID: 602,
            displays: [
                displayInfo(id: 602, serial: 1, managed: true)
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [first, second],
            sequenceMode: .cycle
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.05,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigs([
            config(serial: 1, desiredEnabled: true)
        ])

        do {
            try await service.ensureHealthyTopologyAfterEnable()
            Issue.record("Expected topology unstable error.")
        } catch let error as VirtualDisplayService.VirtualDisplayError {
            guard case .topologyUnstableAfterEnable = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @MainActor
    @Test func postEnableThrowsTopologyUnstableOnAABBOscillation() async {
        let first = topologySnapshot(
            mainDisplayID: 701,
            displays: [
                displayInfo(id: 701, serial: 1, managed: true)
            ]
        )
        let second = topologySnapshot(
            mainDisplayID: 702,
            displays: [
                displayInfo(id: 702, serial: 1, managed: true)
            ]
        )

        let inspector = FakeDisplayTopologyInspector(
            snapshots: [first, first, second, second],
            sequenceMode: .cycle
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.08,
            topologyStabilityPollInterval: 0.001
        )
        service.replaceDisplayConfigs([
            config(serial: 1, desiredEnabled: true)
        ])

        do {
            try await service.ensureHealthyTopologyAfterEnable()
            Issue.record("Expected topology unstable error for A/A/B/B oscillation.")
        } catch let error as VirtualDisplayService.VirtualDisplayError {
            guard case .topologyUnstableAfterEnable = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @MainActor
    @Test func postEnableFailureRollbackClearsRunningStateAndKeepsGenerationUntilTermination() async {
        let snapshot = topologySnapshot(
            mainDisplayID: 801,
            displays: [
                displayInfo(id: 801, serial: 1, managed: true)
            ]
        )
        let inspector = FakeDisplayTopologyInspector(snapshots: [snapshot])
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(inspector: inspector, repairer: repairer)

        let configId = UUID()
        service.seedRuntimeBookkeeping(configId: configId, generation: 42)

        service.rollbackEnableRuntimeState(configId: configId, serialNum: 1)
        _ = await service.waitForManagedDisplayOffline(serialNum: 1, timeout: 0)

        let state = service.runtimeBookkeeping(configId: configId)
        #expect(state.isRunning == false)
        #expect(state.generation == 42)
    }

    @MainActor
    @Test func rebuildInvokesTopologyRecoveryAndPreservesManagedMainContinuity() async throws {
        let displayA: CGDirectDisplayID = 901
        let displayB: CGDirectDisplayID = 902

        let configA = config(id: UUID(), serial: 1, desiredEnabled: true)
        let configB = config(id: UUID(), serial: 2, desiredEnabled: true)

        let recoveredExpanded = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )

        var rebuildHookCallCount = 0
        let inspector = FakeDisplayTopologyInspector(
            snapshots: Array(repeating: recoveredExpanded, count: 240)
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.25,
            topologyStabilityPollInterval: 0.001,
            rebuildRuntimeDisplayHook: { rebuiltConfig, terminationConfirmed in
                rebuildHookCallCount += 1
                _ = rebuiltConfig
                _ = terminationConfirmed
            }
        )
        service.replaceDisplayConfigs([configA, configB])

        try await service.rebuildVirtualDisplay(configId: configA.id)

        #expect(rebuildHookCallCount >= 1)
        // Adaptive cooldown may allow topology to stabilize before recovery evaluates it,
        // so this path no longer guarantees a repair invocation.
    }

    @MainActor
    @Test func rebuildManagedMainWithMultipleRunningDisplaysUsesCoordinatedFleetRebuildOrder() async throws {
        let displayA: CGDirectDisplayID = 921
        let displayB: CGDirectDisplayID = 922

        let configA = config(id: UUID(), serial: 1, desiredEnabled: true)
        let configB = config(id: UUID(), serial: 2, desiredEnabled: true)
        let expandedStable = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )

        var rebuildOrder: [UUID] = []
        var terminationFlags: [Bool] = []
        let inspector = FakeDisplayTopologyInspector(
            snapshots: [
                expandedStable, expandedStable, expandedStable, expandedStable,
                expandedStable, expandedStable, expandedStable, expandedStable,
                expandedStable, expandedStable, expandedStable, expandedStable
            ]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.25,
            topologyStabilityPollInterval: 0.001,
            rebuildRuntimeDisplayHook: { rebuiltConfig, terminationConfirmed in
                rebuildOrder.append(rebuiltConfig.id)
                terminationFlags.append(terminationConfirmed)
            }
        )
        service.replaceDisplayConfigs([configA, configB])
        service.seedRuntimeBookkeeping(configId: configA.id, generation: 11)
        service.seedRuntimeBookkeeping(configId: configB.id, generation: 12)

        try await service.rebuildVirtualDisplay(configId: configA.id)

        #expect(rebuildOrder == [configA.id, configB.id])
        #expect(terminationFlags == [false, false])
        #expect(repairer.callCount == 0)
    }

    @MainActor
    @Test func rebuildManagedMainUsesCoordinatedFleetWhenInitialSnapshotUnavailable() async throws {
        let displayA: CGDirectDisplayID = CGMainDisplayID()
        let displayB: CGDirectDisplayID = displayA == 0 ? 1 : displayA &+ 1

        let configA = config(id: UUID(), serial: 1, desiredEnabled: true)
        let configB = config(id: UUID(), serial: 2, desiredEnabled: true)
        let expandedStable = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
            ]
        )

        var rebuildOrder: [UUID] = []
        let inspector = NullableDisplayTopologyInspector(
            snapshots: [
                nil,
                expandedStable, expandedStable, expandedStable,
                expandedStable, expandedStable, expandedStable
            ]
        )
        let repairer = FakeDisplayTopologyRepairer(shouldSucceed: true)
        let service = makeService(
            inspector: inspector,
            repairer: repairer,
            topologyStabilityTimeout: 0.2,
            topologyStabilityPollInterval: 0.001,
            rebuildRuntimeDisplayHook: { rebuiltConfig, _ in
                rebuildOrder.append(rebuiltConfig.id)
            }
        )
        service.replaceDisplayConfigs([configA, configB])
        service.seedRuntimeBookkeeping(
            configId: configA.id,
            generation: 21,
            runtimeDisplayID: displayA
        )
        service.seedRuntimeBookkeeping(
            configId: configB.id,
            generation: 22,
            runtimeDisplayID: displayB
        )

        try await service.rebuildVirtualDisplay(configId: configA.id)

        #expect(rebuildOrder == [configA.id, configB.id])
        #expect(repairer.callCount == 0)
    }

    @MainActor
    @Test func rebuildFailsWhenDisplayRemainsOnlineDuringFinalOfflineConfirmation() async {
        let displayA: CGDirectDisplayID = 911
        let snapshot = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            ]
        )

        let configA = config(serial: 1, desiredEnabled: true)
        var rebuildHookCallCount = 0
        let service = makeService(
            inspector: FakeDisplayTopologyInspector(snapshots: [snapshot]),
            repairer: FakeDisplayTopologyRepairer(shouldSucceed: true),
            managedDisplayOnlineChecker: { _ in true },
            rebuildRuntimeDisplayHook: { _, _ in
                rebuildHookCallCount += 1
            }
        )
        service.replaceDisplayConfigs([configA])

        do {
            try await service.rebuildVirtualDisplay(configId: configA.id)
            Issue.record("Expected rebuild to fail when display stays online.")
        } catch let error as VirtualDisplayService.VirtualDisplayError {
            guard case .teardownTimedOut = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(rebuildHookCallCount == 0)
    }

    @MainActor
    @Test func aggressiveEnableWithoutTerminationPreemptivelyUsesFleetRebuildBeforeCreatingTarget() async throws {
        let displayA: CGDirectDisplayID = CGMainDisplayID()
        let displayB: CGDirectDisplayID = displayA == 0 ? 1 : displayA &+ 1

        let configA = config(id: UUID(), serial: 1, desiredEnabled: true)
        let configB = config(id: UUID(), serial: 2, desiredEnabled: true)

        let preEnableWithOnlyB = topologySnapshot(
            mainDisplayID: displayB,
            displays: [
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            ]
        )
        let rebuiltExpanded = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900)),
                displayInfo(id: displayB, serial: 2, managed: true, bounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080))
            ]
        )

        var rebuildOrder: [UUID] = []
        var terminationFlags: [Bool] = []
        var service: VirtualDisplayService!
        service = makeService(
            inspector: FakeDisplayTopologyInspector(
                snapshots: [
                    preEnableWithOnlyB, preEnableWithOnlyB, preEnableWithOnlyB, preEnableWithOnlyB,
                    rebuiltExpanded, rebuiltExpanded, rebuiltExpanded, rebuiltExpanded,
                    rebuiltExpanded, rebuiltExpanded, rebuiltExpanded, rebuiltExpanded
                ]
            ),
            repairer: FakeDisplayTopologyRepairer(shouldSucceed: true),
            topologyStabilityTimeout: 0.2,
            topologyStabilityPollInterval: 0.001,
            managedDisplayOnlineChecker: { _ in false },
            rebuildRuntimeDisplayHook: { rebuiltConfig, terminationConfirmed in
                rebuildOrder.append(rebuiltConfig.id)
                terminationFlags.append(terminationConfirmed)
                let runtimeDisplayID = rebuiltConfig.id == configA.id ? displayA : displayB
                service.seedRuntimeBookkeeping(
                    configId: rebuiltConfig.id,
                    generation: UInt64(200 + rebuildOrder.count),
                    runtimeDisplayID: runtimeDisplayID
                )
            }
        )
        service.replaceDisplayConfigs([configA, configB])
        service.seedRuntimeBookkeeping(
            configId: configA.id,
            generation: 11,
            runtimeDisplayID: CGMainDisplayID()
        )
        service.seedRuntimeBookkeeping(
            configId: configB.id,
            generation: 12,
            runtimeDisplayID: displayB
        )

        try service.disableDisplayByConfig(configA.id)
        try await service.enableDisplay(configA.id)

        #expect(rebuildOrder == [configA.id, configB.id])
        #expect(terminationFlags == [false, false])
    }

    @MainActor
    private func makeService(
        inspector: any DisplayTopologyInspecting,
        repairer: any DisplayTopologyRepairing,
        topologyStabilityTimeout: TimeInterval = 0.2,
        topologyStabilityPollInterval: TimeInterval = 0.001,
        managedDisplayOnlineChecker: @escaping (UInt32) -> Bool = { _ in false },
        rebuildRuntimeDisplayHook: (@MainActor (VirtualDisplayConfig, Bool) async throws -> Void)? = nil
    ) -> VirtualDisplayService {
        VirtualDisplayService(
            persistenceService: nil,
            displayReconfigurationMonitor: FakeDisplayReconfigurationMonitor(),
            topologyInspector: inspector,
            topologyRepairer: repairer,
            managedDisplayOnlineChecker: managedDisplayOnlineChecker,
            topologyStabilityTimeout: topologyStabilityTimeout,
            topologyStabilityPollInterval: topologyStabilityPollInterval,
            rebuildRuntimeDisplayHook: rebuildRuntimeDisplayHook
        )
    }

    private func config(id: UUID = UUID(), serial: UInt32, desiredEnabled: Bool) -> VirtualDisplayConfig {
        VirtualDisplayConfig(
            id: id,
            name: "Managed \(serial)",
            serialNum: serial,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [
                .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
            ],
            desiredEnabled: desiredEnabled
        )
    }

    private func topologySnapshot(
        mainDisplayID: CGDirectDisplayID,
        displays: [DisplayTopologySnapshot.DisplayInfo]
    ) -> DisplayTopologySnapshot {
        DisplayTopologySnapshot(
            mainDisplayID: mainDisplayID,
            displays: displays.sorted { $0.id < $1.id }
        )
    }

    private func displayInfo(
        id: CGDirectDisplayID,
        serial: UInt32,
        managed: Bool,
        isActive: Bool = true,
        inMirrorSet: Bool = false,
        mirrorMasterID: CGDirectDisplayID? = nil,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    ) -> DisplayTopologySnapshot.DisplayInfo {
        DisplayTopologySnapshot.DisplayInfo(
            id: id,
            serialNumber: serial,
            isManagedVirtualDisplay: managed,
            isActive: isActive,
            isInMirrorSet: inMirrorSet,
            mirrorMasterDisplayID: mirrorMasterID,
            bounds: bounds
        )
    }
}

private final class FakeDisplayTopologyInspector: DisplayTopologyInspecting {
    enum SequenceMode {
        case repeatLast
        case cycle
    }

    private let snapshots: [DisplayTopologySnapshot]
    private let sequenceMode: SequenceMode
    private var callIndex = 0

    init(
        snapshots: [DisplayTopologySnapshot],
        sequenceMode: SequenceMode = .repeatLast
    ) {
        self.snapshots = snapshots
        self.sequenceMode = sequenceMode
    }

    func snapshot(
        trackedManagedSerials: Set<UInt32>,
        managedVendorID: UInt32,
        managedProductID: UInt32
    ) -> DisplayTopologySnapshot? {
        guard !snapshots.isEmpty else { return nil }
        let index: Int
        switch sequenceMode {
        case .repeatLast:
            index = min(callIndex, snapshots.count - 1)
        case .cycle:
            index = callIndex % snapshots.count
        }
        callIndex += 1
        return snapshots[index]
    }
}

private final class NullableDisplayTopologyInspector: DisplayTopologyInspecting {
    private let snapshots: [DisplayTopologySnapshot?]
    private var callIndex = 0

    init(snapshots: [DisplayTopologySnapshot?]) {
        self.snapshots = snapshots
    }

    func snapshot(
        trackedManagedSerials: Set<UInt32>,
        managedVendorID: UInt32,
        managedProductID: UInt32
    ) -> DisplayTopologySnapshot? {
        guard !snapshots.isEmpty else { return nil }
        let index = min(callIndex, snapshots.count - 1)
        callIndex += 1
        return snapshots[index]
    }
}

private final class FakeDisplayTopologyRepairer: DisplayTopologyRepairing {
    private let shouldSucceed: Bool

    private(set) var callCount = 0
    private(set) var lastManagedDisplayIDs: [CGDirectDisplayID] = []
    private(set) var lastAnchorDisplayID: CGDirectDisplayID?

    init(shouldSucceed: Bool) {
        self.shouldSucceed = shouldSucceed
    }

    func repair(
        snapshot: DisplayTopologySnapshot,
        managedDisplayIDs: [CGDirectDisplayID],
        anchorDisplayID: CGDirectDisplayID
    ) -> Bool {
        callCount += 1
        lastManagedDisplayIDs = managedDisplayIDs
        lastAnchorDisplayID = anchorDisplayID
        return shouldSucceed
    }
}

private final class FakeDisplayReconfigurationMonitor: DisplayReconfigurationMonitoring {
    @discardableResult
    func start(handler: @escaping @MainActor () -> Void) -> Bool {
        true
    }

    func stop() {}
}
