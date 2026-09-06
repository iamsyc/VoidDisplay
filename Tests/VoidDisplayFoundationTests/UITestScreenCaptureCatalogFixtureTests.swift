@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import CoreGraphics
import Testing

@MainActor
struct UITestScreenCaptureCatalogFixtureTests {
    @Test(arguments: [
        UITestScenario.baseline,
        .displayCatalogLoading,
        .displayCatalogLoadingWithMissingManagedDisplay
    ])
    func catalogAndActiveIDsUseTheSameScenario(scenario: UITestScenario) {
        let reservedIDs = Set(UITestRuntime.managedVirtualDisplayIDs)
        let managedDisplayIDs = Set(UITestRuntime.catalogManagedVirtualDisplayIDs(for: scenario))
        let activeDisplayIDs = ScreenCaptureActiveDisplayIDsProviderFactory.makeDefault(
            environment: [
                UITestRuntime.modeEnvironmentKey: "1",
                UITestRuntime.scenarioEnvironmentKey: scenario.rawValue
            ]
        )()
        let shareableDisplayIDs = Set(
            UITestScreenCaptureCatalogFixture.makeShareableDisplays(for: scenario).map(\.displayID)
        )

        #expect(activeDisplayIDs.intersection(reservedIDs) == managedDisplayIDs)
        #expect(shareableDisplayIDs.intersection(reservedIDs) == managedDisplayIDs)
        #expect(activeDisplayIDs == shareableDisplayIDs)
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

    @Test(arguments: [
        UITestScenario.displayCatalogLoading,
        .displayCatalogLoadingWithMissingManagedDisplay
    ])
    func loadingScenariosWaitForThreeSeconds(scenario: UITestScenario) async throws {
        let clock = ManualTestClock()
        let loader = UITestScreenCaptureCatalogFixture.makeLoader(for: scenario, clock: clock)
        let loading = Task { try await loader().map(\.displayID) }
        defer { loading.cancel() }
        try #require(await waitUntil { clock.pendingSleepCount == 1 })

        clock.advance(by: .seconds(2))
        #expect(clock.pendingSleepCount == 1)
        clock.advance(by: .seconds(1))
        try #require(clock.pendingSleepCount == 0)

        let displayIDs = try await loading.value
        let reservedIDs = Set(UITestRuntime.managedVirtualDisplayIDs)
        #expect(
            Set(displayIDs).intersection(reservedIDs)
                == Set(UITestRuntime.catalogManagedVirtualDisplayIDs(for: scenario))
        )
    }

    @Test(arguments: [
        UITestScenario.displayCatalogLoading,
        .displayCatalogLoadingWithMissingManagedDisplay
    ])
    func cancellingFixtureLoadRemovesItsSleep(scenario: UITestScenario) async throws {
        let clock = ManualTestClock()
        let loader = UITestScreenCaptureCatalogFixture.makeLoader(for: scenario, clock: clock)
        let loading = Task { try await loader().map(\.displayID) }
        defer { loading.cancel() }
        try #require(await waitUntil { clock.pendingSleepCount == 1 })

        loading.cancel()

        await #expect(throws: CancellationError.self) { try await loading.value }
        #expect(clock.pendingSleepCount == 0)
    }

    @Test(arguments: [UITestScenario.baseline, .permissionDenied, .menuBarQuickActions])
    func ordinaryScenariosDoNotWait(scenario: UITestScenario) async throws {
        let clock = ManualTestClock()
        let loader = UITestScreenCaptureCatalogFixture.makeLoader(for: scenario, clock: clock)
        var completed = false
        let loading = Task {
            defer { completed = true }
            return try await loader().map(\.displayID)
        }
        defer { loading.cancel() }
        try #require(await waitUntil { completed || clock.pendingSleepCount > 0 })
        try #require(clock.pendingSleepCount == 0)

        let displayIDs = try await loading.value
        #expect(!displayIDs.isEmpty)
    }
}
