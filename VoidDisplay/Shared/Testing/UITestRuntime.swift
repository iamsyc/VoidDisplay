import Foundation

enum UITestScenario: String {
    case baseline
    case capturePreviewDiagnostics = "capture_preview_diagnostics"
    case displayCatalogLoading = "display_catalog_loading"
    case permissionDenied = "permission_denied"
    case settingsFeedback = "settings_feedback"
    case virtualDisplayRebuilding = "virtual_display_rebuilding"
    case virtualDisplayRebuildFailed = "virtual_display_rebuild_failed"
    case virtualDisplayRebuildPending = "virtual_display_rebuild_pending"
}

enum UITestRuntime {
    nonisolated static let modeEnvironmentKey = "VOIDDISPLAY_UI_TEST_MODE"
    nonisolated static let scenarioEnvironmentKey = "VOIDDISPLAY_UI_TEST_SCENARIO"
    nonisolated static let feedbackHappenedEnvironmentKey = "VOIDDISPLAY_FEEDBACK_HAPPENED"
    nonisolated static let feedbackReproductionEnvironmentKey = "VOIDDISPLAY_FEEDBACK_REPRODUCTION"
    nonisolated static let feedbackExpectedEnvironmentKey = "VOIDDISPLAY_FEEDBACK_EXPECTED"
    nonisolated static let feedbackIncludeLogsEnvironmentKey = "VOIDDISPLAY_FEEDBACK_INCLUDE_LOGS"
    nonisolated static let feedbackIncludeCrashEnvironmentKey = "VOIDDISPLAY_FEEDBACK_INCLUDE_CRASH"
    nonisolated static let feedbackIncludeConfigsEnvironmentKey = "VOIDDISPLAY_FEEDBACK_INCLUDE_CONFIGS"

    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[modeEnvironmentKey] == "1"
    }

    nonisolated static var scenario: UITestScenario {
        guard
            let rawValue = ProcessInfo.processInfo.environment[scenarioEnvironmentKey],
            let scenario = UITestScenario(rawValue: rawValue)
        else {
            return .baseline
        }
        return scenario
    }

    nonisolated static var settingsFeedbackFixture: SettingsFeedbackFixture? {
        settingsFeedbackFixture(environment: ProcessInfo.processInfo.environment)
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
        let happened = environment[feedbackHappenedEnvironmentKey] ?? ""
        let reproductionSteps = environment[feedbackReproductionEnvironmentKey] ?? ""
        let expectedResult = environment[feedbackExpectedEnvironmentKey] ?? ""

        guard !happened.isEmpty || !reproductionSteps.isEmpty || !expectedResult.isEmpty else {
            return nil
        }

        return SettingsFeedbackFixture(
            draft: FeedbackDraft(
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
}

nonisolated struct SettingsFeedbackFixture: Sendable {
    let draft: FeedbackDraft
    let consent: FeedbackConsent
}
