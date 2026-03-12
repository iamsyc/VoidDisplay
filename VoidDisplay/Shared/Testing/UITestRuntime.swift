import Foundation

enum UITestScenario: String {
    case baseline
    case capturePreviewDiagnostics = "capture_preview_diagnostics"
    case displayCatalogLoading = "display_catalog_loading"
    case permissionDenied = "permission_denied"
    case virtualDisplayRebuilding = "virtual_display_rebuilding"
    case virtualDisplayRebuildFailed = "virtual_display_rebuild_failed"
    case virtualDisplayRebuildPending = "virtual_display_rebuild_pending"
}

enum UITestRuntime {
    nonisolated static let modeEnvironmentKey = "VOIDDISPLAY_UI_TEST_MODE"
    nonisolated static let scenarioEnvironmentKey = "VOIDDISPLAY_UI_TEST_SCENARIO"

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
