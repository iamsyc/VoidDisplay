import Foundation
import CoreGraphics
package protocol ScreenCapturePermissionProvider {
    nonisolated func preflight() -> Bool
    nonisolated func request() -> Bool
}
package struct SystemScreenCapturePermissionProvider: ScreenCapturePermissionProvider {
    package nonisolated func preflight() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    package nonisolated func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
package struct UITestScreenCapturePermissionProvider: ScreenCapturePermissionProvider {
    package let scenario: UITestScenario

    package nonisolated func preflight() -> Bool {
        switch scenario {
        case .baseline:
            return true
        case .displayCatalogLoading,
             .displayCatalogLoadingWithMissingManagedDisplay:
            return true
        case .settingsFeedback,
             .diagnosticsRecoveredWarning,
             .diagnosticsTransactionTimeline,
             .previewActive,
             .previewRecovery,
             .previewWindowPayload,
             .menuBarQuickActions:
            return true
        case .permissionDenied:
            return false
        }
    }

    package nonisolated func request() -> Bool {
        preflight()
    }
}
package struct XCTestScreenCapturePermissionProvider: ScreenCapturePermissionProvider {
    package nonisolated func preflight() -> Bool {
        false
    }

    package nonisolated func request() -> Bool {
        false
    }
}
package enum ScreenCapturePermissionProviderFactory {
    package static func makeDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any ScreenCapturePermissionProvider {
        if environment[UITestRuntime.modeEnvironmentKey] == "1" {
            let scenario: UITestScenario
            if let rawValue = environment[UITestRuntime.scenarioEnvironmentKey],
               let resolvedScenario = UITestScenario(rawValue: rawValue) {
                scenario = resolvedScenario
            } else {
                scenario = .baseline
            }
            return UITestScreenCapturePermissionProvider(scenario: scenario)
        }

        if environment[PersistenceContext.xCTestConfigurationEnvironmentKey] != nil {
            return XCTestScreenCapturePermissionProvider()
        }

        return SystemScreenCapturePermissionProvider()
    }
}
