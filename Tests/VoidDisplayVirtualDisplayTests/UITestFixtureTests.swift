import Testing
import VoidDisplayFoundation
@testable import VoidDisplayVirtualDisplay

struct UITestFixtureTests {
    @Test(arguments: [UITestScenario.baseline, .displayCatalogLoadingWithMissingManagedDisplay])
    func fixtureIdentitiesMatchScenarioAndRescanHasScrollableContent(scenario: UITestScenario) {
        let configs = UITestFixture.virtualDisplayConfigs(for: scenario)
        #expect(configs.count == UITestRuntime.managedVirtualDisplayIDs(for: scenario).count)
        #expect(Set(configs.map(\.serialNum)).count == configs.count)
        #expect(configs.filter(\.desiredEnabled).count == 2)
        if scenario == .displayCatalogLoadingWithMissingManagedDisplay {
            #expect(configs.count == 3)
            #expect(configs.last?.desiredEnabled == false)
        } else {
            #expect(configs.count == 2)
        }
    }
}
