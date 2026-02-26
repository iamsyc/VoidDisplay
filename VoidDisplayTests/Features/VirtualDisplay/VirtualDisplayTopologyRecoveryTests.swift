import CoreGraphics
import Foundation
import Testing
@testable import VoidDisplay

@MainActor
@Suite(.serialized)
struct VirtualDisplayTopologyRecoveryTests {

    @Test
    func rebuildInvokesHookAndCompletesRecovery() async throws {
        let displayA: CGDirectDisplayID = 901
        let configA = config(id: UUID(), serial: 1, desiredEnabled: true)

        let stable = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            ]
        )

        var rebuildHookCallCount = 0
        let orchestrator = makeOrchestrator(
            initialConfigs: [configA],
            inspector: FakeDisplayTopologyInspector(snapshots: Array(repeating: stable, count: 80)),
            repairer: FakeDisplayTopologyRepairer(shouldSucceed: true),
            topologyStabilityTimeout: 0.2,
            topologyStabilityPollInterval: 0.001,
            rebuildRuntimeDisplayHook: { _, _ in
                rebuildHookCallCount += 1
            }
        )

        try await orchestrator.rebuildVirtualDisplay(configId: configA.id)

        #expect(rebuildHookCallCount == 1)
    }

    @Test
    func rebuildFailsWhenDisplayRemainsOnlineDuringFinalOfflineConfirmation() async {
        let displayA: CGDirectDisplayID = 911
        let configA = config(serial: 1, desiredEnabled: true)
        let stable = topologySnapshot(
            mainDisplayID: displayA,
            displays: [
                displayInfo(id: displayA, serial: 1, managed: true)
            ]
        )

        var rebuildHookCallCount = 0
        let orchestrator = makeOrchestrator(
            initialConfigs: [configA],
            inspector: FakeDisplayTopologyInspector(snapshots: [stable]),
            repairer: FakeDisplayTopologyRepairer(shouldSucceed: true),
            managedDisplayOnlineChecker: { _ in true },
            rebuildRuntimeDisplayHook: { _, _ in
                rebuildHookCallCount += 1
            }
        )

        do {
            try await orchestrator.rebuildVirtualDisplay(configId: configA.id)
            Issue.record("Expected rebuild to fail when display stays online.")
        } catch let error as VirtualDisplayOperationError {
            guard case .teardownTimedOut = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(rebuildHookCallCount == 0)
    }
}

private extension VirtualDisplayTopologyRecoveryTests {
    @MainActor
    func makeOrchestrator(
        initialConfigs: [VirtualDisplayConfig],
        inspector: any DisplayTopologyInspecting,
        repairer: any DisplayTopologyRepairing,
        topologyStabilityTimeout: TimeInterval = 0.2,
        topologyStabilityPollInterval: TimeInterval = 0.001,
        managedDisplayOnlineChecker: @escaping (UInt32) -> Bool = { _ in false },
        rebuildRuntimeDisplayHook: (@MainActor (VirtualDisplayConfig, Bool) async throws -> Void)? = nil
    ) -> VirtualDisplayOrchestrator {
        let clock = TestVirtualDisplayClock()
        let store = FakeVirtualDisplayStore()
        store.nextLoadConfigs = initialConfigs
        let repository = VirtualDisplayConfigRepository(store: store, reportFailure: nil)
        let orchestrator = VirtualDisplayOrchestrator(
            configRepository: repository,
            displayReconfigurationMonitor: FakeDisplayReconfigurationMonitor(),
            topologyInspector: inspector,
            topologyRepairer: repairer,
            managedDisplayOnlineChecker: managedDisplayOnlineChecker,
            topologyStabilityTimeout: topologyStabilityTimeout,
            topologyStabilityPollInterval: topologyStabilityPollInterval,
            rebuildRuntimeDisplayHook: rebuildRuntimeDisplayHook,
            clock: clock
        )
        orchestrator.loadPersistedConfigs()
        return orchestrator
    }

    func config(id: UUID = UUID(), serial: UInt32, desiredEnabled: Bool) -> VirtualDisplayConfig {
        VirtualDisplayConfig(
            id: id,
            displayName: "Managed \(serial)",
            serialNum: serial,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [
                .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
            ],
            desiredEnabled: desiredEnabled
        )
    }

    func topologySnapshot(
        mainDisplayID: CGDirectDisplayID,
        displays: [DisplayTopologySnapshot.DisplayInfo]
    ) -> DisplayTopologySnapshot {
        DisplayTopologySnapshot(
            mainDisplayID: mainDisplayID,
            displays: displays.sorted { $0.id < $1.id }
        )
    }

    func displayInfo(
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
