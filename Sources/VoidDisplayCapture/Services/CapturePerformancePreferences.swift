import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import Observation

public enum CapturePerformancePreferenceKeys {
    public static let mode = "capture.performanceMode"
}
package enum CapturePerformanceMode: String, CaseIterable, Sendable {
    case automatic
    case smooth
    case powerEfficient
}

@MainActor
package protocol CapturePerformancePreferencesProtocol: AnyObject {
    var mode: CapturePerformanceMode { get }
    var onModeChanged: (@MainActor @Sendable (CapturePerformanceMode) -> Void)? { get set }
    func saveMode(_ mode: CapturePerformanceMode)
}

@MainActor
@Observable
package final class CapturePerformancePreferences: CapturePerformancePreferencesProtocol {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored package var onModeChanged: (@MainActor @Sendable (CapturePerformanceMode) -> Void)?
    package var mode: CapturePerformanceMode

    package init(defaults: UserDefaults) {
        self.defaults = defaults
        let rawValue = defaults.string(forKey: CapturePerformancePreferenceKeys.mode)
        self.mode = rawValue.flatMap(CapturePerformanceMode.init(rawValue:)) ?? .automatic
    }

    package func saveMode(_ mode: CapturePerformanceMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        defaults.set(mode.rawValue, forKey: CapturePerformancePreferenceKeys.mode)
        onModeChanged?(mode)
    }
}
