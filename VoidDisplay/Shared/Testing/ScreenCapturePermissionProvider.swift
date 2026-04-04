import CoreGraphics

protocol ScreenCapturePermissionProvider {
    nonisolated func preflight() -> Bool
    nonisolated func request() -> Bool
}

struct SystemScreenCapturePermissionProvider: ScreenCapturePermissionProvider {
    nonisolated func preflight() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    nonisolated func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

struct UITestScreenCapturePermissionProvider: ScreenCapturePermissionProvider {
    let scenario: UITestScenario

    nonisolated func preflight() -> Bool {
        switch scenario {
        case .baseline:
            return true
        case .capturePreviewDiagnostics:
            return true
        case .displayCatalogLoading:
            return true
        case .virtualDisplayRebuilding:
            return true
        case .virtualDisplayRebuildFailed:
            return true
        case .virtualDisplayRebuildPending:
            return true
        case .permissionDenied:
            return false
        }
    }

    nonisolated func request() -> Bool {
        preflight()
    }
}

struct XCTestScreenCapturePermissionProvider: ScreenCapturePermissionProvider {
    nonisolated func preflight() -> Bool {
        false
    }

    nonisolated func request() -> Bool {
        false
    }
}

enum ScreenCapturePermissionProviderFactory {
    static func makeDefault(
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
