@testable import VoidDisplayFoundation
@testable import VoidDisplayVirtualDisplay
import Foundation

final class FakeVirtualDisplayStore: VirtualDisplayStoring {
    var loadCallCount = 0
    var saveCallCount = 0
    var resetCallCount = 0

    var loadError: Error?
    var saveError: Error?
    var scriptedSaveErrors: [Error?] = []
    var resetError: Error?
    var diagnosticsError: Error?

    var nextLoadConfigs: [VirtualDisplayConfig]?
    var savedConfigs: [[VirtualDisplayConfig]] = []
    var diagnosticsValue = VirtualDisplayStoreDiagnostics(
        primaryStoreURL: URL(fileURLWithPath: "/tmp/fake-virtual-displays.json"),
        isTestIsolatedPath: true
    )

    func load() throws -> [VirtualDisplayConfig] {
        loadCallCount += 1
        if let loadError {
            throw loadError
        }
        return nextLoadConfigs ?? savedConfigs.last ?? []
    }

    func save(_ configs: [VirtualDisplayConfig]) throws {
        saveCallCount += 1
        if !scriptedSaveErrors.isEmpty {
            let scriptedError = scriptedSaveErrors.removeFirst()
            if let scriptedError {
                throw scriptedError
            }
            savedConfigs.append(configs)
            return
        }
        if let saveError {
            throw saveError
        }
        savedConfigs.append(configs)
    }

    func reset() throws {
        resetCallCount += 1
        if let resetError {
            throw resetError
        }
        savedConfigs.removeAll()
    }

    func diagnostics() throws -> VirtualDisplayStoreDiagnostics {
        if let diagnosticsError {
            throw diagnosticsError
        }
        return diagnosticsValue
    }
}
