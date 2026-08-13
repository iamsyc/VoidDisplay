@testable import VoidDisplayFoundation
import CoreGraphics
import Testing

@MainActor
struct UITestScreenCaptureCatalogFixtureTests {
    @Test
    func catalogIncludesEveryReservedManagedVirtualDisplay() {
        let managedDisplayIDs = Set(UITestRuntime.managedVirtualDisplayIDs)
        let activeDisplayIDs = UITestScreenCaptureCatalogFixture.activeDisplayIDs()
        let shareableDisplayIDs = Set(
            UITestScreenCaptureCatalogFixture.makeShareableDisplays().map(\.displayID)
        )

        #expect(activeDisplayIDs.isSuperset(of: managedDisplayIDs))
        #expect(shareableDisplayIDs.isSuperset(of: managedDisplayIDs))
    }

    @Test
    func missingManagedDisplayScenarioIsExplicitlyScoped() {
        #expect(
            UITestRuntime.catalogManagedVirtualDisplayIDs(for: .baseline)
                == UITestRuntime.managedVirtualDisplayIDs
        )
        #expect(
            UITestRuntime.catalogManagedVirtualDisplayIDs(
                for: .displayCatalogLoadingWithMissingManagedDisplay
            ) == [UITestRuntime.managedVirtualDisplayIDBase]
        )
    }
}
