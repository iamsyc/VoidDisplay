import Foundation
import Testing
@testable import VoidDisplay

@MainActor
struct VirtualDisplayConfigRepositoryTests {

    @Test
    func loadSuccessSetsReadyStateAndCachesPersistedDisplayNames() {
        let store = FakeVirtualDisplayStore()
        let config = makeConfig(serial: 1, displayName: "Persisted A")
        store.nextLoadConfigs = [config]
        let sut = VirtualDisplayConfigRepository(store: store)

        let loadResult = sut.load()

        switch loadResult {
        case .success(let configs):
            #expect(configs.count == 1)
            #expect(configs.first?.displayName == "Persisted A")
        case .failure(let error):
            Issue.record("Expected load success, got \(error)")
        }
        switch sut.state {
        case .ready(let diagnostics):
            #expect(diagnostics.primaryStoreURL.path == store.diagnosticsValue.primaryStoreURL.path)
        case .loadFailed:
            Issue.record("Expected ready state after successful load")
        }

        var renamed = config
        renamed.displayName = "Runtime Rename"
        let saved = sut.save([renamed], reason: .runtimeDisableCleanup)

        #expect(saved == false)
        #expect(store.saveCallCount == 0)
    }

    @Test
    func loadFailureSetsLoadFailedStateWithDiagnostics() {
        let store = FakeVirtualDisplayStore()
        store.loadError = VirtualDisplayConfigStoreError.unsupportedSchemaVersion(expected: 3, actual: 2)
        var failures: [(String, Error)] = []
        let sut = VirtualDisplayConfigRepository(store: store) { operation, error in
            failures.append((operation, error))
        }

        let loadResult = sut.load()

        switch loadResult {
        case .success:
            Issue.record("Expected load failure")
        case .failure(let error):
            if case .unsupportedSchemaVersion(let expected, let actual) = error {
                #expect(expected == 3)
                #expect(actual == 2)
            } else {
                Issue.record("Expected unsupportedSchemaVersion")
            }
        }
        #expect(failures.count == 1)
        #expect(failures.first?.0 == "Load virtual display configs")
        switch sut.state {
        case .ready:
            Issue.record("Expected loadFailed state")
        case .loadFailed(let error, let diagnostics):
            if case .unsupportedSchemaVersion = error {
            } else {
                Issue.record("Expected unsupportedSchemaVersion in state")
            }
            #expect(diagnostics.primaryStoreURL.path == store.diagnosticsValue.primaryStoreURL.path)
        }
        #expect(sut.loadFailureMessage != nil)
        #expect(sut.diagnosticsSummary.contains("primary="))
    }

    @Test
    func saveIsBlockedWhenStateIsLoadFailed() {
        let store = FakeVirtualDisplayStore()
        store.loadError = VirtualDisplayConfigStoreError.unsupportedSchemaVersion(expected: 3, actual: 2)
        let sut = VirtualDisplayConfigRepository(store: store, reportFailure: nil)
        _ = sut.load()

        let saved = sut.save([makeConfig(serial: 1, displayName: "Blocked")], reason: .userEditedConfig)

        #expect(saved == false)
        #expect(store.saveCallCount == 0)
    }

    @Test
    func saveBlocksDisplayNameMutationForRuntimeReason() {
        let store = FakeVirtualDisplayStore()
        let config = makeConfig(serial: 2, displayName: "Original")
        store.nextLoadConfigs = [config]
        let sut = VirtualDisplayConfigRepository(store: store, reportFailure: nil)
        _ = sut.load()

        var renamed = config
        renamed.displayName = "Managed 2"

        let saved = sut.save([renamed], reason: .runtimeRebuildRecovery)

        #expect(saved == false)
        #expect(store.saveCallCount == 0)
    }

    @Test
    func saveAllowsDisplayNameMutationForUserEditReason() {
        let store = FakeVirtualDisplayStore()
        let config = makeConfig(serial: 3, displayName: "Before")
        store.nextLoadConfigs = [config]
        let sut = VirtualDisplayConfigRepository(store: store, reportFailure: nil)
        _ = sut.load()

        var renamed = config
        renamed.displayName = "After"

        let saved = sut.save([renamed], reason: .userEditedConfig)

        #expect(saved == true)
        #expect(store.saveCallCount == 1)
        #expect(store.savedConfigs.last?.first?.displayName == "After")
    }

    @Test
    func resetClearsLoadFailedStateAndSnapshots() {
        let store = FakeVirtualDisplayStore()
        store.loadError = VirtualDisplayConfigStoreError.unsupportedSchemaVersion(expected: 3, actual: 2)
        let sut = VirtualDisplayConfigRepository(store: store, reportFailure: nil)
        _ = sut.load()

        let reset = sut.reset()

        #expect(reset == true)
        #expect(store.resetCallCount == 1)
        switch sut.state {
        case .ready(let diagnostics):
            #expect(diagnostics.primaryStoreURL.path == store.diagnosticsValue.primaryStoreURL.path)
        case .loadFailed:
            Issue.record("Expected ready state after reset")
        }

        let config = makeConfig(serial: 4, displayName: "Fresh")
        let saved = sut.save([config], reason: .userCreatedConfig)
        #expect(saved == true)
        #expect(store.saveCallCount == 1)
    }

    @Test
    func resetFailureDoesNotFallbackToSavingEmptyConfigs() {
        let store = FakeVirtualDisplayStore()
        store.resetError = NSError(domain: "test", code: 22)
        var failures: [(String, Int)] = []
        let sut = VirtualDisplayConfigRepository(store: store) { operation, error in
            failures.append((operation, (error as NSError).code))
        }

        let reset = sut.reset()

        #expect(reset == false)
        #expect(store.resetCallCount == 1)
        #expect(store.saveCallCount == 0)
        #expect(failures.map(\.0) == ["Reset virtual display configs"])
        #expect(failures.map(\.1) == [22])
    }

    private func makeConfig(serial: UInt32, displayName: String) -> VirtualDisplayConfig {
        VirtualDisplayConfig(
            displayName: displayName,
            serialNum: serial,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
    }
}
