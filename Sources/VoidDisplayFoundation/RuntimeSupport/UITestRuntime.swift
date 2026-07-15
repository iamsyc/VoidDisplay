import Foundation
package enum UITestScenario: String {
    case baseline
    case displayCatalogLoading = "display_catalog_loading"
    case permissionDenied = "permission_denied"
    case settingsFeedback = "settings_feedback"
    case previewRecovery = "preview_recovery"
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
    package nonisolated static let windowWidthEnvironmentKey = "VOIDDISPLAY_UI_TEST_WINDOW_WIDTH"
    package nonisolated static let windowHeightEnvironmentKey = "VOIDDISPLAY_UI_TEST_WINDOW_HEIGHT"
    package nonisolated static let advanceFocusEnvironmentKey = "VOIDDISPLAY_UI_TEST_ADVANCE_FOCUS"

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

    package nonisolated static var windowSize: UITestWindowSize? {
        windowSize(environment: ProcessInfo.processInfo.environment)
    }

    package nonisolated static var shouldAdvanceFocus: Bool {
        shouldAdvanceFocus(environment: ProcessInfo.processInfo.environment)
    }

    package nonisolated static func shouldAdvanceFocus(
        environment: [String: String]
    ) -> Bool {
        environment[modeEnvironmentKey] == "1"
            && environment[advanceFocusEnvironmentKey] == "1"
    }

    package nonisolated static func windowSize(
        environment: [String: String]
    ) -> UITestWindowSize? {
        guard environment[modeEnvironmentKey] == "1",
              let widthValue = environment[windowWidthEnvironmentKey],
              let heightValue = environment[windowHeightEnvironmentKey],
              let width = Double(widthValue),
              let height = Double(heightValue),
              width > 0,
              height > 0
        else {
            return nil
        }
        return UITestWindowSize(width: width, height: height)
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

package nonisolated struct UITestWindowSize: Equatable, Sendable {
    package let width: Double
    package let height: Double

    package init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}
