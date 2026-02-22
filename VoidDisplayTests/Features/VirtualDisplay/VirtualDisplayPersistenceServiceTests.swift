import Foundation
import Testing
@testable import VoidDisplay

@MainActor
struct VirtualDisplayPersistenceServiceTests {

    @Test func loadReturnsEmptyWhenStoreThrows() {
        let store = MockVirtualDisplayStore()
        store.loadError = NSError(domain: "test", code: 1)
        let sut = VirtualDisplayPersistenceService(store: store)

        let configs = sut.loadConfigs()

        #expect(configs.isEmpty)
        #expect(store.loadCallCount == 1)
    }

    @Test func resetFallsBackToSavingEmptyConfigsWhenResetFails() {
        let store = MockVirtualDisplayStore()
        store.resetError = NSError(domain: "test", code: 2)
        let sut = VirtualDisplayPersistenceService(store: store)

        sut.resetConfigs()

        #expect(store.resetCallCount == 1)
        #expect(store.saveCallCount == 1)
        #expect(store.savedConfigs.last?.isEmpty == true)
    }

    @Test func resetDoesNotFallbackWhenResetSucceeds() {
        let store = MockVirtualDisplayStore()
        let sut = VirtualDisplayPersistenceService(store: store)

        sut.resetConfigs()

        #expect(store.resetCallCount == 1)
        #expect(store.saveCallCount == 0)
    }

    @Test func restoreDesiredVirtualDisplaysOnlyRestoresEnabledAndCollectsFailures() {
        let sut = VirtualDisplayPersistenceService(store: MockVirtualDisplayStore())
        let enabledA = makeConfig(serial: 1, desiredEnabled: true)
        let disabled = makeConfig(serial: 2, desiredEnabled: false)
        let enabledB = makeConfig(serial: 3, desiredEnabled: true)

        var restoredSerials: [UInt32] = []
        let failures = sut.restoreDesiredVirtualDisplays(
            from: [enabledA, disabled, enabledB]
        ) { config in
            restoredSerials.append(config.serialNum)
            if config.serialNum == 3 {
                throw NSError(domain: "restore", code: 99)
            }
        }

        #expect(restoredSerials == [1, 3])
        #expect(failures.count == 1)
        #expect(failures.first?.serialNum == 3)
        #expect(failures.first?.name == enabledB.name)
    }

    private func makeConfig(serial: UInt32, desiredEnabled: Bool) -> VirtualDisplayConfig {
        VirtualDisplayConfig(
            name: "Display \(serial)",
            serialNum: serial,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: desiredEnabled
        )
    }
}

private final class MockVirtualDisplayStore: VirtualDisplayStoring {
    var loadCallCount = 0
    var saveCallCount = 0
    var resetCallCount = 0

    var loadError: Error?
    var saveError: Error?
    var resetError: Error?

    var nextLoadConfigs: [VirtualDisplayConfig] = []
    var savedConfigs: [[VirtualDisplayConfig]] = []

    func load() throws -> [VirtualDisplayConfig] {
        loadCallCount += 1
        if let loadError {
            throw loadError
        }
        return nextLoadConfigs
    }

    func save(_ configs: [VirtualDisplayConfig]) throws {
        saveCallCount += 1
        savedConfigs.append(configs)
        if let saveError {
            throw saveError
        }
    }

    func reset() throws {
        resetCallCount += 1
        if let resetError {
            throw resetError
        }
    }
}
