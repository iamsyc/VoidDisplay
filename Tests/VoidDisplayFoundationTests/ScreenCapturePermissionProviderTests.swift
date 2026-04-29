@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import Testing

@MainActor
struct ScreenCapturePermissionProviderTests {
    @Test func makeDefaultUsesUITestScenarioProviderWhenUITestModeIsEnabled() {
        let provider = ScreenCapturePermissionProviderFactory.makeDefault(
            environment: [
                UITestRuntime.modeEnvironmentKey: "1",
                UITestRuntime.scenarioEnvironmentKey: UITestScenario.permissionDenied.rawValue
            ]
        )

        #expect(provider.preflight() == false)
        #expect(provider.request() == false)
    }

    @Test func makeDefaultUsesNonInteractiveProviderWhenRunningUnderXCTest() {
        let provider = ScreenCapturePermissionProviderFactory.makeDefault(
            environment: [
                PersistenceContext.xCTestConfigurationEnvironmentKey: "/tmp/test.xctestconfiguration"
            ]
        )

        #expect(provider.preflight() == false)
        #expect(provider.request() == false)
    }
}
