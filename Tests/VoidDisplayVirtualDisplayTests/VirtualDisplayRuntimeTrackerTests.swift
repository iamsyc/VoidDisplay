@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayFoundation
import CoreGraphics
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct VirtualDisplayRuntimeTrackerTests {
    @Test
    func createRuntimeDisplayUsesDriverAndReturnsRecord() throws {
        let driver = FakeVirtualDisplayRuntimeDriver(
            scriptedResults: [.success(serialNum: 22, displayID: 920)]
        )
        let tracker = makeTracker(runtimeDriver: driver)
        let config = makeConfig(serial: 22)

        let record = try tracker.createRuntimeDisplay(from: config)

        #expect(record.configId == config.id)
        #expect(record.serialNum == 22)
        #expect(record.displayID == 920)
        #expect(record.generation == 1)
        #expect(tracker.isVirtualDisplayRunning(configId: config.id))
        #expect(tracker.runtimeGeneration(for: config.id) == 1)
        #expect(tracker.runtimeDisplayID(for: config.id) == 920)
        #expect(tracker.activeSerialNumbers == [22])
    }

    @Test
    func createRuntimeDisplayWithRetriesRetriesCreationFailedThenSucceeds() async throws {
        let driver = FakeVirtualDisplayRuntimeDriver(
            scriptedResults: [
                .failure(VirtualDisplayOperationError.creationFailed),
                .success(serialNum: 33, displayID: 933)
            ]
        )
        let tracker = makeTracker(runtimeDriver: driver)
        let config = makeConfig(serial: 33)

        let record = try await tracker.createRuntimeDisplayWithRetries(
            from: config,
            terminationConfirmed: false
        )

        #expect(record.displayID == 933)
        #expect(driver.createCallCount == 2)
    }

    @Test
    func createRuntimeDisplayWithRetriesDoesNotRetryNonCreationFailure() async {
        let driver = FakeVirtualDisplayRuntimeDriver(
            scriptedResults: [
                .failure(VirtualDisplayOperationError.invalidConfiguration("bad-mode"))
            ]
        )
        let tracker = makeTracker(runtimeDriver: driver)
        let config = makeConfig(serial: 44)

        do {
            _ = try await tracker.createRuntimeDisplayWithRetries(
                from: config,
                terminationConfirmed: false
            )
            Issue.record("Expected invalidConfiguration error")
        } catch let error as VirtualDisplayOperationError {
            guard case .invalidConfiguration = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(driver.createCallCount == 1)
    }

    @Test
    func terminationCallbackClearsRuntimeState() throws {
        let driver = FakeVirtualDisplayRuntimeDriver(
            scriptedResults: [.success(serialNum: 55, displayID: 955)]
        )
        let tracker = makeTracker(runtimeDriver: driver)
        let config = makeConfig(serial: 55)
        _ = try tracker.createRuntimeDisplay(from: config)

        driver.triggerTermination(for: config.id)

        #expect(tracker.isVirtualDisplayRunning(configId: config.id) == false)
        #expect(tracker.runtimeGeneration(for: config.id) == nil)
        #expect(tracker.runtimeDisplayID(for: config.id) == nil)
    }

    @Test
    func staleTerminationCallbackIsIgnoredWhenGenerationAdvanced() throws {
        let driver = FakeVirtualDisplayRuntimeDriver(
            scriptedResults: [.success(serialNum: 66, displayID: 966)]
        )
        let tracker = makeTracker(runtimeDriver: driver)
        let config = makeConfig(serial: 66)
        _ = try tracker.createRuntimeDisplay(from: config)
        tracker.clearRuntimeTracking(configId: config.id, keepGeneration: true)
        tracker.markConfigRunning(configId: config.id, generation: 2, runtimeDisplayID: 777)

        driver.triggerTermination(for: config.id)

        #expect(tracker.isVirtualDisplayRunning(configId: config.id))
        #expect(tracker.runtimeGeneration(for: config.id) == 2)
        #expect(tracker.runtimeDisplayID(for: config.id) == 777)
    }

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

        tracker.rollbackEnableRuntimeState(configId: configID)

        #expect(tracker.isVirtualDisplayRunning(configId: configID) == false)
        #expect(tracker.runtimeGeneration(for: configID) == 15)
        #expect(tracker.runtimeDisplayID(for: configID) == nil)
    }

    @Test
    func clearRuntimeTrackingCanDropGeneration() {
        let tracker = makeTracker()
        let configID = UUID()
        tracker.markConfigRunning(configId: configID, generation: 3, runtimeDisplayID: 800)

        tracker.clearRuntimeTracking(configId: configID, keepGeneration: false)

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
        runtimeDriver: (any VirtualDisplayRuntimeDriving)? = nil,
        onlineChecker: @escaping (UInt32) -> Bool = { _ in false }
    ) -> VirtualDisplayRuntimeTracker {
        let teardownCoordinator = DisplayTeardownCoordinator(
            managedDisplayOnlineChecker: onlineChecker,
            isReconfigurationMonitorAvailable: false
        )
        return VirtualDisplayRuntimeTracker(
            teardownCoordinator: teardownCoordinator,
            runtimeDriver: runtimeDriver ?? FakeVirtualDisplayRuntimeDriver(scriptedResults: [])
        )
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

@MainActor
private final class FakeVirtualDisplayRuntimeDriver: VirtualDisplayRuntimeDriving {
    enum CreateResult {
        case success(serialNum: UInt32, displayID: CGDirectDisplayID)
        case failure(Error)
    }

    private let scriptedResults: [CreateResult]
    private var nextIndex = 0
    private var terminationHandlersByConfigId: [UUID: @MainActor () -> Void] = [:]

    private(set) var createCallCount = 0

    init(scriptedResults: [CreateResult]) {
        self.scriptedResults = scriptedResults
    }

    func createRuntimeDisplay(
        from config: VirtualDisplayConfig,
        maxPixels: (width: UInt32, height: UInt32)?,
        onTermination: @escaping @MainActor () -> Void
    ) throws -> any VirtualDisplayRuntimeHandling {
        _ = maxPixels
        createCallCount += 1
        terminationHandlersByConfigId[config.id] = onTermination
        let result: CreateResult
        if scriptedResults.indices.contains(nextIndex) {
            result = scriptedResults[nextIndex]
        } else {
            result = .success(serialNum: config.serialNum, displayID: CGDirectDisplayID(10_000 + createCallCount))
        }
        nextIndex += 1
        switch result {
        case .success(let serialNum, let displayID):
            return FakeVirtualDisplayRuntimeHandle(serialNum: serialNum, displayID: displayID)
        case .failure(let error):
            throw error
        }
    }

    func triggerTermination(for configId: UUID) {
        terminationHandlersByConfigId[configId]?()
    }
}

@MainActor
private final class FakeVirtualDisplayRuntimeHandle: VirtualDisplayRuntimeHandling {
    let serialNum: UInt32
    let displayID: CGDirectDisplayID

    init(serialNum: UInt32, displayID: CGDirectDisplayID) {
        self.serialNum = serialNum
        self.displayID = displayID
    }

    func applyModes(_ modes: [ResolutionSelection]) -> Bool {
        !modes.isEmpty
    }
}
