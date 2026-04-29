import Foundation
package enum UITestScenario: String {
    case baseline
    case capturePreviewDiagnostics = "capture_preview_diagnostics"
    case displayCatalogLoading = "display_catalog_loading"
    case permissionDenied = "permission_denied"
    case settingsFeedback = "settings_feedback"
    case virtualDisplayRebuilding = "virtual_display_rebuilding"
    case virtualDisplayRebuildFailed = "virtual_display_rebuild_failed"
    case virtualDisplayRebuildPending = "virtual_display_rebuild_pending"
}
package enum UITestRuntime {
    package nonisolated static let modeEnvironmentKey = "VOIDDISPLAY_UI_TEST_MODE"
    package nonisolated static let scenarioEnvironmentKey = "VOIDDISPLAY_UI_TEST_SCENARIO"
    package nonisolated static let feedbackIssueTypeEnvironmentKey = "VOIDDISPLAY_FEEDBACK_ISSUE_TYPE"
    package nonisolated static let feedbackHappenedEnvironmentKey = "VOIDDISPLAY_FEEDBACK_HAPPENED"
    package nonisolated static let feedbackReproductionEnvironmentKey = "VOIDDISPLAY_FEEDBACK_REPRODUCTION"
    package nonisolated static let feedbackExpectedEnvironmentKey = "VOIDDISPLAY_FEEDBACK_EXPECTED"
    package nonisolated static let feedbackIncludeLogsEnvironmentKey = "VOIDDISPLAY_FEEDBACK_INCLUDE_LOGS"
    package nonisolated static let feedbackIncludeCrashEnvironmentKey = "VOIDDISPLAY_FEEDBACK_INCLUDE_CRASH"
    package nonisolated static let feedbackIncludeConfigsEnvironmentKey = "VOIDDISPLAY_FEEDBACK_INCLUDE_CONFIGS"
    package nonisolated static let feedbackExportFailureMessageEnvironmentKey = "VOIDDISPLAY_FEEDBACK_EXPORT_FAILURE_MESSAGE"

    package nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[modeEnvironmentKey] == "1"
    }

    package nonisolated static var scenario: UITestScenario {
        guard
            let rawValue = ProcessInfo.processInfo.environment[scenarioEnvironmentKey],
            let scenario = UITestScenario(rawValue: rawValue)
        else {
            return .baseline
        }
        return scenario
    }

    package nonisolated static var feedbackExportFailureMessage: String? {
        feedbackExportFailureMessage(environment: ProcessInfo.processInfo.environment)
    }

    package nonisolated static func feedbackExportFailureMessage(
        environment: [String: String]
    ) -> String? {
        let message = environment[feedbackExportFailureMessageEnvironmentKey]
        guard let trimmedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmedMessage.isEmpty == false else {
            return nil
        }
        return trimmedMessage
    }
}
