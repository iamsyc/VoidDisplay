@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayFoundation
@testable import VoidDisplayVirtualDisplayTestingSupport
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayTeardownCoordinatorOfflineWaitTests {

    @Test
    func waitForOfflineFallsBackToPollingWhenMonitorUnavailable() async {
        let state = ManagedOnlineState(isOnline: true)
        let clock = TestVirtualDisplayClock()
        let coordinator = DisplayTeardownCoordinator(
            managedDisplayOnlineChecker: { _ in state.isOnline },
            isReconfigurationMonitorAvailable: false,
            clock: clock
        )

        let flipTask = Task { @MainActor in
            await Task.yield()
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
        let clock = TestVirtualDisplayClock()
        let coordinator = DisplayTeardownCoordinator(
            managedDisplayOnlineChecker: { _ in state.isOnline },
            isReconfigurationMonitorAvailable: true,
            clock: clock
        )

        let flipTask = Task { @MainActor in
            await Task.yield()
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
        let clock = TestVirtualDisplayClock()
        let coordinator = DisplayTeardownCoordinator(
            managedDisplayOnlineChecker: { _ in state.isOnline },
            isReconfigurationMonitorAvailable: true,
            clock: clock
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
