import VoidDisplayFoundation
import CoreVideo
import Synchronization

package final class TestDisplayShareFrameConsumer: DisplayShareFrameConsumer {
    private struct State {
        var hasDemand = false
        var demandHandler: @Sendable (Bool) -> Void = { _ in }
    }

    private let state = Mutex(State())

    package nonisolated init() {}

    package nonisolated var hasDemand: Bool {
        state.withLock { $0.hasDemand }
    }

    package nonisolated func updateDemandHandler(
        _ onDemandChanged: @escaping @Sendable (Bool) -> Void
    ) {
        state.withLock { $0.demandHandler = onDemandChanged }
    }

    package nonisolated func setHasDemand(_ hasDemand: Bool) {
        let callback = state.withLock { state -> (@Sendable (Bool) -> Void)? in
            guard state.hasDemand != hasDemand else { return nil }
            state.hasDemand = hasDemand
            return state.demandHandler
        }
        callback?(hasDemand)
    }

    package nonisolated func updateSourceVideoSpec(_ spec: SourceVideoSpec) {
        _ = spec
    }

    package nonisolated func updatePerformanceMode(_ mode: CapturePerformanceMode) {
        _ = mode
    }

    package nonisolated func stopSharing() {}

    package nonisolated func submitFrame(pixelBuffer _: CVPixelBuffer, ptsUs _: UInt64) {}
}
