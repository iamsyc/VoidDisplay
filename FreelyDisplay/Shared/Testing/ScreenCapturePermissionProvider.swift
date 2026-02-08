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
        case .permissionDenied:
            return false
        }
    }

    nonisolated func request() -> Bool {
        preflight()
    }
}

enum ScreenCapturePermissionProviderFactory {
    static func makeDefault() -> any ScreenCapturePermissionProvider {
        guard UITestRuntime.isEnabled else {
            return SystemScreenCapturePermissionProvider()
        }
        return UITestScreenCapturePermissionProvider(scenario: UITestRuntime.scenario)
    }
}
