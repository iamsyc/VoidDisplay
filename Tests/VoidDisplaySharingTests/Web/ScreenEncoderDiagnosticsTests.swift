import CoreVideo
import Testing
@testable import VoidDisplaySharing
@preconcurrency import WebRTC

struct ScreenEncoderDiagnosticsTests {
    @Test func unstartedEncoderReportsInputFailureAndReleaseLeavesNoFrames() throws {
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixelBuffer) == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        let encoder = ScreenVideoEncoder()
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1)
        #expect(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: []) == -1)
        #expect(encoder.diagnostics.inputFrames == 1)
        #expect(encoder.diagnostics.inputFailures == 1)
        #expect(encoder.diagnostics.capacityDrops == 0)
        #expect(encoder.diagnostics.submittedFrames == 0)
        #expect(encoder.release() == 0)
        #expect(encoder.diagnostics.inFlightFrames == 0)
        #expect(encoder.diagnostics.releasedFrames == 0)
    }
}
