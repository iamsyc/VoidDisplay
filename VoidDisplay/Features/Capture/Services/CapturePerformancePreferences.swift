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
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onModeChanged: (@MainActor @Sendable (CapturePerformanceMode) -> Void)?
    var mode: CapturePerformanceMode

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let rawValue = defaults.string(forKey: CapturePerformancePreferenceKeys.mode)
        self.mode = rawValue.flatMap(CapturePerformanceMode.init(rawValue:)) ?? .automatic
    }

    func saveMode(_ mode: CapturePerformanceMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        defaults.set(mode.rawValue, forKey: CapturePerformancePreferenceKeys.mode)
        onModeChanged?(mode)
    }
}
