import Testing
@testable import VoidDisplay

struct UITestRuntimeTests {
    @Test func settingsFeedbackFixtureResolvesInjectedDraftAndConsent() {
        let fixture = UITestRuntime.settingsFeedbackFixture(
            environment: [
                UITestRuntime.scenarioEnvironmentKey: UITestScenario.settingsFeedback.rawValue,
                UITestRuntime.feedbackHappenedEnvironmentKey: "black screen",
                UITestRuntime.feedbackReproductionEnvironmentKey: "open settings",
                UITestRuntime.feedbackExpectedEnvironmentKey: "content appears",
                UITestRuntime.feedbackIncludeLogsEnvironmentKey: "1",
                UITestRuntime.feedbackIncludeConfigsEnvironmentKey: "1"
            ]
        )

        #expect(fixture?.draft.happened == "black screen")
        #expect(fixture?.draft.reproductionSteps == "open settings")
        #expect(fixture?.draft.expectedResult == "content appears")
        #expect(fixture?.consent.includeUnifiedLogSummary == true)
        #expect(fixture?.consent.includeCrashReportExcerpt == false)
        #expect(fixture?.consent.includeRelatedConfigSnapshots == true)
    }

    @Test func settingsFeedbackFixtureReturnsNilWithoutInjectedDraft() {
        let fixture = UITestRuntime.settingsFeedbackFixture(
            environment: [
                UITestRuntime.scenarioEnvironmentKey: UITestScenario.settingsFeedback.rawValue
            ]
        )

        #expect(fixture == nil)
    }
}
