import Foundation
import Testing
@testable import FreelyDisplay

struct VirtualDisplayServiceOfflineWaitTests {

    @MainActor
    @Test func waitForOfflineFallsBackToPollingWhenMonitorUnavailable() async {
        let monitor = FakeDisplayReconfigurationMonitor(startResult: false)
        let state = ManagedOnlineState(isOnline: true)
        let sut = VirtualDisplayService(
            persistenceService: nil,
            displayReconfigurationMonitor: monitor,
            managedDisplayOnlineChecker: { _ in state.isOnline }
        )

        let flipTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            state.isOnline = false
        }
        defer { flipTask.cancel() }

        let result = await sut.waitForManagedDisplayOfflineForTesting(
            serialNum: 42,
            timeout: 0.35
        )

        #expect(result)
        #expect(monitor.startCallCount == 1)
    }

    @MainActor
    @Test func waitForOfflineUsesFinalRecheckWhenCallbackDoesNotArrive() async {
        let monitor = FakeDisplayReconfigurationMonitor(startResult: true)
        let state = ManagedOnlineState(isOnline: true)
        let sut = VirtualDisplayService(
            persistenceService: nil,
            displayReconfigurationMonitor: monitor,
            managedDisplayOnlineChecker: { _ in state.isOnline }
        )

        let flipTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            state.isOnline = false
        }
        defer { flipTask.cancel() }

        let result = await sut.waitForManagedDisplayOfflineForTesting(
            serialNum: 99,
            timeout: 0.2
        )

        #expect(result)
        #expect(monitor.startCallCount == 1)
        #expect(monitor.handler != nil)
    }

    @MainActor
    @Test func waitForOfflineReturnsFalseWhenStillOnlineAtTimeout() async {
        let monitor = FakeDisplayReconfigurationMonitor(startResult: true)
        let state = ManagedOnlineState(isOnline: true)
        let sut = VirtualDisplayService(
            persistenceService: nil,
            displayReconfigurationMonitor: monitor,
            managedDisplayOnlineChecker: { _ in state.isOnline }
        )

        let result = await sut.waitForManagedDisplayOfflineForTesting(
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

private final class FakeDisplayReconfigurationMonitor: DisplayReconfigurationMonitoring {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var handler: (@MainActor () -> Void)?

    private let startResult: Bool

    init(startResult: Bool) {
        self.startResult = startResult
    }

    @discardableResult
    func start(handler: @escaping @MainActor () -> Void) -> Bool {
        startCallCount += 1
        self.handler = handler
        return startResult
    }

    func stop() {
        stopCallCount += 1
        handler = nil
    }
}
