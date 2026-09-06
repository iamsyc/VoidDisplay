@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayFoundation
import CoreGraphics
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct VirtualDisplayRuntimeTrackerTests {
    @Test(arguments: [false, true])
    func modeBoundsAgreeAcrossCreationPersistenceAndRuntime(reverse: Bool) async throws {
        let scenarios: [([VirtualDisplayConfig.ModeConfig], UInt32, UInt32)] = [
            ([.init(width: 5120, height: 2880, refreshRate: 60, enableHiDPI: false),
              .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: true)], 5120, 2880),
            ([.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false),
              .init(width: 1080, height: 1920, refreshRate: 60, enableHiDPI: false)], 1920, 1920),
            ([.init(width: 3000, height: 1000, refreshRate: 60, enableHiDPI: false),
              .init(width: 1000, height: 2000, refreshRate: 60, enableHiDPI: true)], 3000, 4000),
            ([.init(width: 4096, height: 4096, refreshRate: 60, enableHiDPI: true)], 8192, 8192)
        ]
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".ai-tmp/mode-bounds-tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VirtualDisplayStore(storeURL: root.appendingPathComponent("displays.json"), mode: .testIsolatedWritable)
        for (modes, width, height) in scenarios {
            var config = makeConfig(serial: 97)
            config.modes = reverse ? Array(modes.reversed()) : modes
            let creationBounds = CreateVirtualDisplayInputValidator.maxPixelDimensions(for: config.resolutionModes)
            #expect(creationBounds == .resolved(width: width, height: height))
            #expect(config.maxPixelDimensions.width == width)
            #expect(config.maxPixelDimensions.height == height)
            try store.save([config])
            let loaded = try #require(store.load().first)
            #expect(loaded == config)
            guard case .resolved(let creationWidth, let creationHeight) = creationBounds else { continue }
            for useCreationDimensions in [false, true] {
                let driver = FakeVirtualDisplayRuntimeDriver(scriptedResults: [])
                let tracker = makeTracker(runtimeDriver: driver)
                _ = try await tracker.createRuntimeDisplay(
                    from: loaded, maxPixels: useCreationDimensions ? (creationWidth, creationHeight) : nil
                )
                #expect(driver.createdDescriptors.first?.maximumPixelDimensions == .init(width: width, height: height))
            }
        }
    }

    @Test func pendingCreationReservesSerialNumber() async throws {
        let driver = FakeVirtualDisplayRuntimeDriver(scriptedResults: [])
        let tracker = makeTracker(runtimeDriver: driver)
        let config = makeConfig(serial: 91)
        var resume: CheckedContinuation<Void, Never>?
        driver.beforeReturning = { await withCheckedContinuation { resume = $0 } }
        let task = Task { try await tracker.createRuntimeDisplay(from: config) }
        while resume == nil { await Task.yield() }
        #expect(tracker.activeSerialNumbers.contains(91))
        await #expect(throws: VirtualDisplayOperationError.self) {
            _ = try await tracker.createRuntimeDisplay(from: makeConfig(serial: 91))
        }
        #expect(driver.createCallCount == 1)
        resume?.resume()
        _ = try await task.value
    }

    @Test func clearingPendingCreationRejectsLateReadyHandle() async {
        let driver = FakeVirtualDisplayRuntimeDriver(scriptedResults: [])
        let tracker = makeTracker(runtimeDriver: driver)
        let config = makeConfig(serial: 92)
        var resume: CheckedContinuation<Void, Never>?
        driver.beforeReturning = { await withCheckedContinuation { resume = $0 } }
        let task = Task { try await tracker.createRuntimeDisplay(from: config) }
        while resume == nil { await Task.yield() }
        tracker.clearRuntimeTracking(configId: config.id, keepGeneration: false)
        resume?.resume()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!tracker.hasActiveRuntimeDisplay(configId: config.id))
        #expect(!tracker.isVirtualDisplayRunning(configId: config.id))
        #expect(tracker.runtimeGeneration(for: config.id) == nil)
        #expect(tracker.activeSerialNumbers.isEmpty)
    }

    @Test func cancellingPendingCreationKeepsGenerationUntilTerminationArrives() async {
        let driver = FakeVirtualDisplayRuntimeDriver(scriptedResults: [])
        let tracker = makeTracker(runtimeDriver: driver)
        let config = makeConfig(serial: 94)
        var resume: CheckedContinuation<Void, Never>?
        driver.beforeReturning = { await withCheckedContinuation { resume = $0 } }
        let task = Task { try await tracker.createRuntimeDisplay(from: config) }
        while resume == nil { await Task.yield() }
        let generation = tracker.runtimeGeneration(for: config.id)
        tracker.clearRuntimeTracking(configId: config.id, keepGeneration: true)
        resume?.resume()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(generation != nil)
        #expect(tracker.runtimeGeneration(for: config.id) == generation)
        driver.triggerTermination(for: config.id)
        #expect(tracker.runtimeGeneration(for: config.id) == nil)
    }

    @Test func resetWhileCreatingCannotOverwriteReplacementRuntime() async throws {
        let driver = FakeVirtualDisplayRuntimeDriver(scriptedResults: [])
        let tracker = makeTracker(runtimeDriver: driver)
        let config = makeConfig(serial: 95)
        var resume: CheckedContinuation<Void, Never>?
        driver.beforeReturning = { await withCheckedContinuation { resume = $0 } }
        let oldTask = Task { try await tracker.createRuntimeDisplay(from: config) }
        while resume == nil { await Task.yield() }
        tracker.resetAll()
        driver.beforeReturning = nil
        let replacement = try await tracker.createRuntimeDisplay(from: config)
        resume?.resume()
        await #expect(throws: CancellationError.self) { _ = try await oldTask.value }
        #expect(tracker.runtimeGeneration(for: config.id) == replacement.generation)
        #expect(tracker.runtimeDisplayID(for: config.id) == replacement.displayID)
        #expect(tracker.isVirtualDisplayRunning(configId: config.id))
    }

    @Test func configRemovedDuringCreateReleasesReadyRuntime() async {
        let driver = FakeVirtualDisplayRuntimeDriver(scriptedResults: [])
        let tracker = makeTracker(runtimeDriver: driver)
        let config = makeConfig(serial: 96)
        var available = true
        driver.beforeReturning = { available = false }
        await #expect(throws: VirtualDisplayOperationError.self) {
            _ = try await tracker.createRuntimeDisplayWithRetries(from: config, terminationConfirmed: true) { available }
        }
        #expect(!tracker.hasActiveRuntimeDisplay(configId: config.id))
        #expect(tracker.runningConfigIDs().isEmpty)
    }

    @Test func terminationBeforeReadyCannotCommitDeadRuntime() async {
        let driver = FakeVirtualDisplayRuntimeDriver(scriptedResults: [])
        let tracker = makeTracker(runtimeDriver: driver)
        let config = makeConfig(serial: 93)
        driver.beforeReturning = { driver.triggerTermination(for: config.id) }
        await #expect(throws: VirtualDisplayOperationError.self) {
            _ = try await tracker.createRuntimeDisplay(from: config)
        }
        #expect(!tracker.hasActiveRuntimeDisplay(configId: config.id))
        #expect(tracker.runtimeGeneration(for: config.id) == nil)
    }

    @Test
    func createRuntimeDisplayUsesDriverAndReturnsRecord() async throws {
        let driver = FakeVirtualDisplayRuntimeDriver(
            scriptedResults: [.success(serialNum: 22, displayID: 920)]
        )
        let tracker = makeTracker(runtimeDriver: driver)
        let config = makeConfig(serial: 22)

        let record = try await tracker.createRuntimeDisplay(from: config)

        #expect(record.configId == config.id)
        #expect(record.serialNum == 22)
        #expect(record.displayID == 920)
        #expect(record.generation == 1)
        #expect(tracker.isVirtualDisplayRunning(configId: config.id))
        #expect(tracker.runtimeGeneration(for: config.id) == 1)
        #expect(tracker.runtimeDisplayID(for: config.id) == 920)
        #expect(tracker.activeSerialNumbers == [22])
        #expect(driver.createdDescriptors == [
            VirtualDisplayRuntimeDescriptor(
                name: "Managed 22",
                serialNumber: 22,
                physicalSize: CGSize(width: 300, height: 200),
                maximumPixelDimensions: .init(width: 1920, height: 1080),
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, isHiDPI: false)]
            )
        ])
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
            terminationConfirmed: false,
            configIsAvailable: { true }
        )

        #expect(record.displayID == 933)
        #expect(driver.createCallCount == 2)
    }

    @Test(arguments: [false, true])
    func hostExitBeforeCreationCompletesStillRetries(returnsReady: Bool) async throws {
        let driver = FakeVirtualDisplayRuntimeDriver(scriptedResults: [])
        let tracker = makeTracker(runtimeDriver: driver)
        let config = makeConfig(serial: 96)
        driver.beforeReturning = {
            guard driver.createCallCount == 1 else { return }
            driver.triggerTermination(for: config.id)
            // The production driver preserves explicit cancellation when its pipe closes.
            try Task.checkCancellation()
            if !returnsReady { throw VirtualDisplayOperationError.creationFailed }
        }

        let record = try await tracker.createRuntimeDisplayWithRetries(
            from: config, terminationConfirmed: true, configIsAvailable: { true }
        )

        #expect(driver.createCallCount == 2)
        #expect(tracker.runtimeDisplayID(for: config.id) == record.displayID)
        #expect(tracker.isVirtualDisplayRunning(configId: config.id))
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
            let record = try await tracker.createRuntimeDisplayWithRetries(
                from: config,
                terminationConfirmed: false,
                configIsAvailable: { true }
            )
            Issue.record("Expected invalidConfiguration error, got \(record).")
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
    func terminationCallbackClearsRuntimeState() async throws {
        let driver = FakeVirtualDisplayRuntimeDriver(
            scriptedResults: [.success(serialNum: 55, displayID: 955)]
        )
        let tracker = makeTracker(runtimeDriver: driver)
        let config = makeConfig(serial: 55)
        _ = try await tracker.createRuntimeDisplay(from: config)

        driver.triggerTermination(for: config.id)

        #expect(tracker.isVirtualDisplayRunning(configId: config.id) == false)
        #expect(tracker.runtimeGeneration(for: config.id) == nil)
        #expect(tracker.runtimeDisplayID(for: config.id) == nil)
    }

    @Test
    func staleTerminationCallbackIsIgnoredWhenGenerationAdvanced() async throws {
        let driver = FakeVirtualDisplayRuntimeDriver(
            scriptedResults: [.success(serialNum: 66, displayID: 966)]
        )
        let tracker = makeTracker(runtimeDriver: driver)
        let config = makeConfig(serial: 66)
        _ = try await tracker.createRuntimeDisplay(from: config)
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
    var beforeReturning: (() async throws -> Void)?
    private var latestTerminationHandler: (@MainActor () -> Void)?

    private(set) var createCallCount = 0
    private(set) var createdDescriptors: [VirtualDisplayRuntimeDescriptor] = []

    init(scriptedResults: [CreateResult]) {
        self.scriptedResults = scriptedResults
    }

    func createRuntimeDisplay(
        descriptor: VirtualDisplayRuntimeDescriptor,
        onTermination: @escaping @MainActor () -> Void
    ) async throws -> any VirtualDisplayRuntimeHandling {
        createCallCount += 1
        createdDescriptors.append(descriptor)
        latestTerminationHandler = onTermination
        try await beforeReturning?()
        let result: CreateResult
        if scriptedResults.indices.contains(nextIndex) {
            result = scriptedResults[nextIndex]
        } else {
            result = .success(
                serialNum: descriptor.serialNumber,
                displayID: CGDirectDisplayID(10_000 + createCallCount)
            )
        }
        nextIndex += 1
        switch result {
        case .success(let serialNum, let displayID):
            return FakeVirtualDisplayRuntimeHandle(serialNum: serialNum, displayID: displayID)
        case .failure(let error):
            throw error
        }
    }

    func triggerTermination(for _: UUID) {
        latestTerminationHandler?()
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

}
