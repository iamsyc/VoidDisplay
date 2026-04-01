import Foundation
import Observation

public enum CapturePerformancePreferenceKeys {
    public static let mode = "capture.performanceMode"
}

enum CapturePerformanceMode: String, CaseIterable, Sendable {
    case automatic
    case smooth
    case powerEfficient
}

@MainActor
protocol CapturePerformancePreferencesProtocol: AnyObject {
    var mode: CapturePerformanceMode { get }
    var onModeChanged: (@MainActor @Sendable (CapturePerformanceMode) -> Void)? { get set }
    func saveMode(_ mode: CapturePerformanceMode)
}

@MainActor
@Observable
final class CapturePerformancePreferences: CapturePerformancePreferencesProtocol {
    private let defaults: UserDefaults
    var onModeChanged: (@MainActor @Sendable (CapturePerformanceMode) -> Void)?

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var mode: CapturePerformanceMode {
        let rawValue = defaults.string(forKey: CapturePerformancePreferenceKeys.mode)
        return rawValue.flatMap(CapturePerformanceMode.init(rawValue:)) ?? .automatic
    }

    func saveMode(_ mode: CapturePerformanceMode) {
        guard self.mode != mode else { return }
        defaults.set(mode.rawValue, forKey: CapturePerformancePreferenceKeys.mode)
        onModeChanged?(mode)
    }
}
