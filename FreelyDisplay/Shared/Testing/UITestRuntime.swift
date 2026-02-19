import Foundation

enum UITestScenario: String {
    case baseline
    case permissionDenied = "permission_denied"
    case virtualDisplayRebuilding = "virtual_display_rebuilding"
    case virtualDisplayRebuildFailed = "virtual_display_rebuild_failed"
}

enum UITestRuntime {
    nonisolated static let modeEnvironmentKey = "FREELYDISPLAY_UI_TEST_MODE"
    nonisolated static let scenarioEnvironmentKey = "FREELYDISPLAY_UI_TEST_SCENARIO"

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
}
