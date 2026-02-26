import Foundation
import Testing
@testable import VoidDisplay

@MainActor
@Suite(.serialized)
struct VirtualDisplayServiceOfflineWaitTests {

    @Test
    func waitForOfflineFallsBackToPollingWhenMonitorUnavailable() async {
        let state = ManagedOnlineState(isOnline: true)
        let coordinator = DisplayTeardownCoordinator(
            managedDisplayOnlineChecker: { _ in state.isOnline },
            isReconfigurationMonitorAvailable: false
        )

        let flipTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            state.isOnline = false
        }
        defer { flipTask.cancel() }

        let result = await coordinator.waitForManagedDisplayOffline(
            serialNum: 42,
            timeout: 1.2
        )

        #expect(result)
    }

    @Test
    func waitForOfflineUsesFinalRecheckWhenCallbackDoesNotArrive() async {
        let state = ManagedOnlineState(isOnline: true)
        let coordinator = DisplayTeardownCoordinator(
            managedDisplayOnlineChecker: { _ in state.isOnline },
            isReconfigurationMonitorAvailable: true
        )

        let flipTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            state.isOnline = false
        }
        defer { flipTask.cancel() }

        let result = await coordinator.waitForManagedDisplayOffline(
            serialNum: 99,
            timeout: 0.2
        )

        #expect(result)
    }

    @Test
    func waitForOfflineReturnsFalseWhenStillOnlineAtTimeout() async {
        let state = ManagedOnlineState(isOnline: true)
        let coordinator = DisplayTeardownCoordinator(
            managedDisplayOnlineChecker: { _ in state.isOnline },
            isReconfigurationMonitorAvailable: true
        )

        let result = await coordinator.waitForManagedDisplayOffline(
            serialNum: 7,
            timeout: 0.08
        )

        #expect(result == false)
    }
}

@MainActor
private final class ManagedOnlineState {
    var isOnline: Bool

    init(isOnline: Bool) {
        self.isOnline = isOnline
    }
}
