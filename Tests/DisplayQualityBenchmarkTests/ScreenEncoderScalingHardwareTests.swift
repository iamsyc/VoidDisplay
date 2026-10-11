import CoreVideo
import Foundation
import Synchronization
import Testing
import VoidDisplaySharing
@preconcurrency import WebRTC

extension ScreenEncoderHardwareTests {
    @Test func scalingScratchTracksHighWaterAndResetsAcrossSessions() throws {
        let encoder = ScreenVideoEncoder()
        let output = Mutex<[(UInt32, Int32, Int32)]>([])
        encoder.setCallback { image, _ in
            output.withLock { $0.append((image.timeStamp, image.encodedWidth, image.encodedHeight)) }
            return true
        }
        defer { _ = encoder.release(); encoder.setCallback(nil) }
        var identity: UInt32 = 0
        for (width, height) in [(1920, 1080), (1280, 720), (1920, 1080)] {
            #expect(encoder.startEncode(with: settings(width: width, height: height), numberOfCores: 1) == 0)
            #expect(encoder.scalingScratchByteCount == 0)
            var highWater = 0
            // Includes the direct copy path, growth, reuse, shrink and growth
            // again within one session; then restarts at different dimensions.
            for (multiplier, cropped) in [(1, false), (2, false), (2, true), (1, false), (2, false)] {
                let source = try makeBuffer(width: width * multiplier, height: height * multiplier)
                let native = cropped
                    ? RTCCVPixelBuffer(pixelBuffer: source, adaptedWidth: Int32(width), adaptedHeight: Int32(height),
                                       cropWidth: Int32(width * 3 / 2), cropHeight: Int32(height * 3 / 2), cropX: 16, cropY: 16)
                    : RTCCVPixelBuffer(pixelBuffer: source)
                let required = multiplier == 1 ? 0 : Int(native.bufferSizeForCroppingAndScaling(toWidth: Int32(width), height: Int32(height)))
                highWater = max(highWater, required)
                identity += 1
                let input = RTCVideoFrame(buffer: native, rotation: ._0, timeStampNs: Int64(identity) * 16_666_667)
                input.timeStamp = Int32(bitPattern: identity)
                #expect(encoder.encode(input, codecSpecificInfo: nil, frameTypes: []) == 0)
                #expect(encoder.scalingScratchByteCount == highWater)
                let expectedID = identity
                #expect(waitUntil { output.withLock { $0.last?.0 == expectedID } })
                #expect(output.withLock { $0.last?.1 == Int32(width) && $0.last?.2 == Int32(height) })
            }
            #expect(highWater > 0)
            #expect(encoder.release() == 0)
            #expect(encoder.scalingScratchByteCount == 0)
        }
        #expect(output.withLock { $0.count } == 15)
        #expect(encoder.encode(frame(try makeBuffer(width: 640, height: 360), id: identity + 1), codecSpecificInfo: nil, frameTypes: []) == -1)
        #expect(encoder.scalingScratchByteCount == 0)
    }

    @Test func failedRestartReleasesScalingScratch() throws {
        let encoder = ScreenVideoEncoder()
        defer { _ = encoder.release() }
        #expect(encoder.startEncode(with: settings(width: 640, height: 360), numberOfCores: 1) == 0)
        #expect(encoder.encode(frame(try makeBuffer(width: 1280, height: 720), id: 1), codecSpecificInfo: nil, frameTypes: []) == 0)
        #expect(encoder.scalingScratchByteCount > 0)
        #expect(encoder.startEncode(with: settings(width: 0, height: 0), numberOfCores: 1) != 0)
        #expect(encoder.scalingScratchByteCount == 0)
        #expect(encoder.diagnostics.inFlightFrames == 0)
    }
}
