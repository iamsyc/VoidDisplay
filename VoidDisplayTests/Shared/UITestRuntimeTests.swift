import Testing
@testable import VoidDisplay

struct UITestRuntimeTests {
    @Test func feedbackFixtureResolvesInjectedDraftOutsideSettingsScenario() {
        let fixture = UITestRuntime.feedbackFixture(
            environment: [
                UITestRuntime.scenarioEnvironmentKey: UITestScenario.baseline.rawValue,
                UITestRuntime.feedbackIssueTypeEnvironmentKey: SupportIssueType.blackScreen.rawValue,
                UITestRuntime.feedbackHappenedEnvironmentKey: "screen stays black"
            ]
        )

        #expect(fixture?.draft.issueType == .blackScreen)
        #expect(fixture?.draft.happened == "screen stays black")
    }

    @Test func settingsFeedbackFixtureResolvesInjectedDraftAndConsent() {
        let fixture = UITestRuntime.settingsFeedbackFixture(
            environment: [
                UITestRuntime.scenarioEnvironmentKey: UITestScenario.settingsFeedback.rawValue,
                UITestRuntime.feedbackIssueTypeEnvironmentKey: SupportIssueType.virtualDisplayFailure.rawValue,
                UITestRuntime.feedbackHappenedEnvironmentKey: "black screen",
                UITestRuntime.feedbackReproductionEnvironmentKey: "open settings",
                UITestRuntime.feedbackExpectedEnvironmentKey: "content appears",
                UITestRuntime.feedbackIncludeLogsEnvironmentKey: "1",
                UITestRuntime.feedbackIncludeConfigsEnvironmentKey: "1"
            ]
        )

        #expect(fixture?.draft.issueType == .virtualDisplayFailure)
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

    @Test func feedbackExportFailureMessageResolvesNonEmptyValue() {
        let message = UITestRuntime.feedbackExportFailureMessage(
            environment: [
                UITestRuntime.feedbackExportFailureMessageEnvironmentKey: "Injected export failure"
            ]
        )

        #expect(message == "Injected export failure")
    }
}
