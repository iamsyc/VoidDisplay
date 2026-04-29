@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import Foundation
import Testing

@MainActor
struct PersistenceWriteGuardTests {

    @Test func testModeBlocksWritesToProductionRoot() throws {
        let context = PersistenceContext.resolve(
            environment: [PersistenceContext.xCTestConfigurationEnvironmentKey: "/tmp/test.xctestconfiguration"]
        )
        let productionTarget = try productionRootURL(from: context)
            .appendingPathComponent("display-share-id-mappings.json", isDirectory: false)

        let allowed = context.guardWriteAllowed(
            targetURL: productionTarget,
            operation: "unit-test-write-guard"
        )

        #expect(allowed == false)
    }

    @Test func testModeAllowsWritesToIsolatedRoot() {
        let context = PersistenceContext.resolve(
            environment: [PersistenceContext.persistenceModeEnvironmentKey: PersistenceContext.testIsolatedModeValue]
        )
        let isolatedTarget = context.appSupportRootURL
            .appendingPathComponent("virtual-displays.json", isDirectory: false)

        let allowed = context.guardWriteAllowed(
            targetURL: isolatedTarget,
            operation: "unit-test-isolated-write"
        )

        #expect(allowed)
    }

    @Test func productionModeAllowsWritesToProductionRoot() {
        let context = PersistenceContext.resolve(environment: [:])
        let productionTarget = context.appSupportRootURL
            .appendingPathComponent("display-share-id-mappings.json", isDirectory: false)

        let allowed = context.guardWriteAllowed(
            targetURL: productionTarget,
            operation: "unit-test-production-write"
        )

        #expect(allowed)
    }

    private func productionRootURL(from context: PersistenceContext) throws -> URL {
        guard let testsRange = context.bundleIdentifier.range(of: ".tests") else {
            throw TestError("Expected test bundle identifier containing .tests, got \(context.bundleIdentifier)")
        }
        let baseBundleID = String(context.bundleIdentifier[..<testsRange.lowerBound])
        return context.appSupportRootURL
            .deletingLastPathComponent()
            .appendingPathComponent(baseBundleID, isDirectory: true)
    }

    private struct TestError: Error {
        let message: String

        init(_ message: String) {
            self.message = message
        }
    }
}
