/// Counts belong to one encoder session. A callback rejection is an observation
/// at the WebRTC handoff, not proof of network loss or sender backpressure.
package nonisolated struct ScreenEncoderDiagnostics: Codable, Sendable, Equatable {
    package var inputFrames = 0
    package var submittedFrames = 0
    package var capacityDrops = 0
    package var deferredFrames = 0
    package var resumedFrames = 0
    package var inputFailures = 0
    package var compressionFailures = 0
    package var hardwareDrops = 0
    package var outputFailures = 0
    package var outputFrames = 0
    package var callbackRejections = 0
    package var releasedFrames = 0
    package var releasedPendingFrames = 0
    package var inFlightFrames = 0
    package var pendingFrames = 0
    package var peakInFlightFrames = 0
}
