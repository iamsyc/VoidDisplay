import Foundation
import Testing
@testable import VoidDisplay

@MainActor
struct PersistenceContextTests {

    @Test func resolveProductionModeByDefault() {
        let context = PersistenceContext.resolve(environment: [:])

        #expect(context.mode == .production)
        #expect(context.bundleIdentifier.hasSuffix(".tests") == false)
        #expect(context.appSupportRootURL.lastPathComponent == context.bundleIdentifier)
        #expect(context.displayShareIDMappingsURL.lastPathComponent == "display-share-id-mappings.json")
        #expect(context.virtualDisplayConfigsURL.lastPathComponent == "virtual-displays.json")
    }

    @Test func resolveTestModeWhenXCTestEnvironmentExists() {
        let context = PersistenceContext.resolve(
            environment: [PersistenceContext.xCTestConfigurationEnvironmentKey: "/tmp/test.xctestconfiguration"]
        )

        #expect(context.mode == .testIsolatedWritable)
        #expect(context.bundleIdentifier.contains(".tests"))
        #expect(context.appSupportRootURL.lastPathComponent == context.bundleIdentifier)
    }

    @Test func resolveTestModeWhenUITestFlagExists() {
        let context = PersistenceContext.resolve(
            environment: [PersistenceContext.uiTestModeEnvironmentKey: "1"]
        )

        #expect(context.mode == .testIsolatedWritable)
        #expect(context.bundleIdentifier.contains(".tests"))
    }

    @Test func resolveUsesExplicitIsolationIdentifierForTestMode() {
        let context = PersistenceContext.resolve(
            environment: [
                PersistenceContext.uiTestModeEnvironmentKey: "1",
                PersistenceContext.testIsolationIDEnvironmentKey: "suite-A"
            ]
        )

        #expect(context.mode == .testIsolatedWritable)
        #expect(context.bundleIdentifier.hasSuffix(".tests.suite-A"))
    }

    @Test func testModeUsesIsolatedUserDefaultsSuite() {
        let context = PersistenceContext.resolve(
            environment: [PersistenceContext.persistenceModeEnvironmentKey: PersistenceContext.testIsolatedModeValue]
        )
        let key = "persistence-context-tests.\(UUID().uuidString)"
        defer {
            context.userDefaults.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }

        context.userDefaults.set(42, forKey: key)

        #expect(context.userDefaults.integer(forKey: key) == 42)
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }
}
