import CoreGraphics
import Foundation
import Testing
@testable import VoidDisplay

@MainActor
@Suite(.serialized)
struct VirtualDisplayRuntimeTrackerTests {
    @Test
    func markConfigRunningStoresGenerationAndHint() {
        let tracker = makeTracker()
        let configID = UUID()

        tracker.markConfigRunning(configId: configID, generation: 9, runtimeDisplayID: 501)

        #expect(tracker.isVirtualDisplayRunning(configId: configID))
        #expect(tracker.runtimeGeneration(for: configID) == 9)
        #expect(tracker.runtimeDisplayID(for: configID) == 501)
        #expect(tracker.runningConfigCount == 1)
    }

    @Test
    func rollbackEnableRuntimeStateClearsRunningButKeepsGeneration() {
        let tracker = makeTracker()
        let configID = UUID()
        tracker.markConfigRunning(configId: configID, generation: 15, runtimeDisplayID: 700)

        tracker.rollbackEnableRuntimeState(configId: configID, serialNum: 1)

        #expect(tracker.isVirtualDisplayRunning(configId: configID) == false)
        #expect(tracker.runtimeGeneration(for: configID) == 15)
        #expect(tracker.runtimeDisplayID(for: configID) == nil)
    }

    @Test
    func clearRuntimeTrackingCanDropGeneration() {
        let tracker = makeTracker()
        let configID = UUID()
        tracker.markConfigRunning(configId: configID, generation: 3, runtimeDisplayID: 800)

        tracker.clearRuntimeTracking(configId: configID, serialNum: 1, keepGeneration: false)

        #expect(tracker.isVirtualDisplayRunning(configId: configID) == false)
        #expect(tracker.runtimeGeneration(for: configID) == nil)
        #expect(tracker.runtimeDisplayID(for: configID) == nil)
    }

    @Test
    func runtimeDisplayIDForSerialUsesConfigHintLookupWhenNoRuntimeObject() {
        let tracker = makeTracker()
        let config = makeConfig(serial: 22)
        tracker.markConfigRunning(configId: config.id, generation: 2, runtimeDisplayID: 920)

        let runtimeID = tracker.runtimeDisplayIDForSerial(22, configs: [config])

        #expect(runtimeID == 920)
    }

    @Test
    func runtimeSerialNumFallsBackWhenNoActiveRuntimeObject() {
        let tracker = makeTracker()

        let serial = tracker.runtimeSerialNum(for: UUID(), fallback: 77)

        #expect(serial == 77)
    }

    @Test
    func waitForManagedDisplayOfflineUsesTeardownCoordinator() async {
        let tracker = makeTracker(onlineChecker: { _ in false })

        let offline = await tracker.waitForManagedDisplayOffline(serialNum: 10, timeout: 0.1)

        #expect(offline)
    }

    @Test
    func resetAllClearsAllBookkeepingState() {
        let tracker = makeTracker()
        let configID = UUID()
        tracker.markConfigRunning(configId: configID, generation: 20, runtimeDisplayID: 333)

        tracker.resetAll()

        #expect(tracker.runningConfigCount == 0)
        #expect(tracker.runtimeGeneration(for: configID) == nil)
        #expect(tracker.runtimeDisplayID(for: configID) == nil)
        #expect(tracker.activeSerialNumbers.isEmpty)
    }
}

private extension VirtualDisplayRuntimeTrackerTests {
    func makeTracker(
        onlineChecker: @escaping (UInt32) -> Bool = { _ in false }
    ) -> VirtualDisplayRuntimeTracker {
        let teardownCoordinator = DisplayTeardownCoordinator(
            managedDisplayOnlineChecker: onlineChecker,
            isReconfigurationMonitorAvailable: false
        )
        return VirtualDisplayRuntimeTracker(teardownCoordinator: teardownCoordinator)
    }

    func makeConfig(serial: UInt32) -> VirtualDisplayConfig {
        VirtualDisplayConfig(
            id: UUID(),
            displayName: "Managed \(serial)",
            serialNum: serial,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
    }
}
