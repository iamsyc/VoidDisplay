@testable import VoidDisplayObservability
@testable import VoidDisplayFoundation
import Foundation
import Testing

struct UITestRuntimeTests {
    @Test func previewRecoveryCopyHasValuesForEveryLocalization() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Apps/VoidDisplay/Resources/Localizable.xcstrings"
            )
        )
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try #require(root["strings"] as? [String: Any])
        let expectedLanguages: Set<String> = ["en", "zh-Hans"]
        let keys = [
            "Close",
            "Preview Could Not Be Restored",
            "Reconnecting to the rebuilt display…",
            "Restoring Preview",
            "Retry",
            "Screen Recording permission is unavailable. Retry after restoring access, or close this window.",
            "The rebuilt display is no longer available. Retry or close this window.",
            "The preview could not be restored. Retry or close this window."
        ]

        for key in keys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(Set(localizations.keys) == expectedLanguages)
            for language in expectedLanguages {
                let localization = try #require(localizations[language] as? [String: Any])
                let unit = try #require(localization["stringUnit"] as? [String: Any])
                let value = try #require(unit["value"] as? String)
                #expect(!value.isEmpty)
            }
        }
    }

    @Test func windowSizeRequiresUITestModeAndPositiveDimensions() {
        let configured = UITestRuntime.windowSize(environment: [
            UITestRuntime.modeEnvironmentKey: "1",
            UITestRuntime.windowWidthEnvironmentKey: "760",
            UITestRuntime.windowHeightEnvironmentKey: "640"
        ])

        #expect(configured == UITestWindowSize(width: 760, height: 640))
        #expect(UITestRuntime.windowSize(environment: [
            UITestRuntime.windowWidthEnvironmentKey: "760",
            UITestRuntime.windowHeightEnvironmentKey: "640"
        ]) == nil)
        #expect(UITestRuntime.windowSize(environment: [
            UITestRuntime.modeEnvironmentKey: "1",
            UITestRuntime.windowWidthEnvironmentKey: "0",
            UITestRuntime.windowHeightEnvironmentKey: "640"
        ]) == nil)
    }

    @Test func focusTraversalInjectionRequiresUITestMode() {
        #expect(UITestRuntime.shouldAdvanceFocus(environment: [
            UITestRuntime.modeEnvironmentKey: "1",
            UITestRuntime.advanceFocusEnvironmentKey: "1"
        ]))
        #expect(!UITestRuntime.shouldAdvanceFocus(environment: [
            UITestRuntime.advanceFocusEnvironmentKey: "1"
        ]))
    }

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
