import VoidDisplayFoundation
import CoreVideo

package final class TestDisplayShareFrameConsumer: DisplayShareFrameConsumer {
    package nonisolated init() {}

    package nonisolated var hasDemand: Bool { false }

    package nonisolated func updatePerformanceMode(_ mode: CapturePerformanceMode) {
        _ = mode
    }

    package nonisolated func stopSharing() {}

    package nonisolated func submitFrame(pixelBuffer _: CVPixelBuffer, ptsUs _: UInt64) {}
}
