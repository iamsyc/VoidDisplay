import Foundation
import Testing
@testable import VoidDisplay

@MainActor
struct DisplayTeardownCoordinatorTests {

    @Test func waitForManagedDisplayOfflineReturnsTrueImmediatelyWhenAlreadyOffline() async {
        let coordinator = DisplayTeardownCoordinator(
            managedDisplayOnlineChecker: { _ in false },
            isReconfigurationMonitorAvailable: true
        )

        let result = await coordinator.waitForManagedDisplayOffline(
            serialNum: 42,
            timeout: 0.2
        )

        #expect(result)
    }

    @Test func waitForTeardownSettlementTerminationObservedEarlyShortCircuitsAsSettled() async {
        let configID = UUID()
        let generation: UInt64 = 11
        let coordinator = DisplayTeardownCoordinator(
            managedDisplayOnlineChecker: { _ in true },
            isReconfigurationMonitorAvailable: true
        )
        coordinator.setRuntimeGenerationProvider { id in
            id == configID ? generation : nil
        }

        let task = Task { @MainActor in
            await coordinator.waitForTeardownSettlement(
                configId: configID,
                expectedGeneration: generation,
                serialNum: 99,
                terminationTimeout: 2.0,
                offlineTimeout: 2.0
            )
        }

        for _ in 0..<8 {
            coordinator.observeTermination(configId: configID, generation: generation)
            await Task.yield()
        }

        let settlement = await task.value
        #expect(settlement.terminationObserved)
        #expect(settlement.offlineConfirmed)
    }

    @Test func waitForTeardownSettlementOfflineConfirmedEarlyReturnsWithoutTermination() async {
        let configID = UUID()
        let generation: UInt64 = 21
        let serial: UInt32 = 123
        var onlineSerials: Set<UInt32> = [serial]
        let coordinator = DisplayTeardownCoordinator(
            managedDisplayOnlineChecker: { queriedSerial in
                onlineSerials.contains(queriedSerial)
            },
            isReconfigurationMonitorAvailable: true
        )
        coordinator.setRuntimeGenerationProvider { id in
            id == configID ? generation : nil
        }

        let task = Task { @MainActor in
            await coordinator.waitForTeardownSettlement(
                configId: configID,
                expectedGeneration: generation,
                serialNum: serial,
                terminationTimeout: 2.0,
                offlineTimeout: 2.0
            )
        }

        for _ in 0..<8 {
            onlineSerials.remove(serial)
            coordinator.completeOfflineWaitersIfPossible()
            await Task.yield()
        }

        let settlement = await task.value
        #expect(settlement.terminationObserved == false)
        #expect(settlement.offlineConfirmed)
    }
}
