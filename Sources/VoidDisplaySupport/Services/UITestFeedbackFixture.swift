import Foundation
import VoidDisplayFoundation
import VoidDisplayObservability

package nonisolated struct SettingsFeedbackFixture: Sendable {
    package let draft: FeedbackDraft
    package let consent: FeedbackConsent
}

package extension UITestRuntime {
    nonisolated static var feedbackFixture: SettingsFeedbackFixture? {
        feedbackFixture(environment: ProcessInfo.processInfo.environment)
    }

    nonisolated static var settingsFeedbackFixture: SettingsFeedbackFixture? {
        settingsFeedbackFixture(environment: ProcessInfo.processInfo.environment)
    }

    nonisolated static func feedbackFixture(
        environment: [String: String]
    ) -> SettingsFeedbackFixture? {
        let issueType = environment[feedbackIssueTypeEnvironmentKey]
            .flatMap(SupportIssueType.init(rawValue:))
            ?? .other
        let happened = environment[feedbackHappenedEnvironmentKey] ?? ""
        let reproductionSteps = environment[feedbackReproductionEnvironmentKey] ?? ""
        let expectedResult = environment[feedbackExpectedEnvironmentKey] ?? ""

        guard !happened.isEmpty || !reproductionSteps.isEmpty || !expectedResult.isEmpty else {
            return nil
        }

        return SettingsFeedbackFixture(
            draft: FeedbackDraft(
                issueType: issueType,
                happened: happened,
                reproductionSteps: reproductionSteps,
                expectedResult: expectedResult
            ),
            consent: FeedbackConsent(
                includeUnifiedLogSummary: environment[feedbackIncludeLogsEnvironmentKey] == "1",
                includeCrashReportExcerpt: environment[feedbackIncludeCrashEnvironmentKey] == "1",
                includeRelatedConfigSnapshots: environment[feedbackIncludeConfigsEnvironmentKey] == "1"
            )
        )
    }

    nonisolated static func settingsFeedbackFixture(
        environment: [String: String]
    ) -> SettingsFeedbackFixture? {
        guard
            let rawValue = environment[scenarioEnvironmentKey],
            let scenario = UITestScenario(rawValue: rawValue),
            scenario == .settingsFeedback
        else {
            return nil
        }
        return feedbackFixture(environment: environment)
    }
}
