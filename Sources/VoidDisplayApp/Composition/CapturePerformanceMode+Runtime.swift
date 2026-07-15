import VoidDisplayFoundation
import VoidDisplayRuntime

package extension CapturePerformanceMode {
    var runtimeCapturePowerProfile: DisplayRuntimeCapturePowerProfile {
        switch self {
        case .automatic:
            .automatic
        case .smooth:
            .smooth
        case .powerEfficient:
            .powerEfficient
        }
    }
}
