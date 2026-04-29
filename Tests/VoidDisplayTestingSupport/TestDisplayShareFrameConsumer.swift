import VoidDisplayFoundation
import CoreVideo

package final class TestDisplayShareFrameConsumer: DisplayShareFrameConsumer {
    package nonisolated init() {}

    package nonisolated var hasDemand: Bool { false }

    package nonisolated func stopSharing() {}

    package nonisolated func submitFrame(pixelBuffer: CVPixelBuffer, ptsUs: UInt64) {
        _ = pixelBuffer
        _ = ptsUs
    }
}
