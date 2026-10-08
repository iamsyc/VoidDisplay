import CoreVideo
import Foundation
import Synchronization
import Testing
import VoidDisplaySharing
@preconcurrency import WebRTC

/// Explicit local hardware gate; ordinary CI/unit runs never start a codec.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VOIDDISPLAY_ENCODER_HARDWARE_TESTS"] == "1"))
struct ScreenEncoderHardwareTests {
    @Test(arguments: [1, 2]) func lastInputRecoversAfterBackpressureWithoutNewInput(slots: Int) throws {
        let encoder = ScreenVideoEncoder(maximumInFlightFrames: slots)
        let output = Mutex<[UInt32]>([])
        let injected = Mutex(false)
        let buffer = try makeBuffer(width: 5120, height: 2880)
        let expected = UInt32(slots + 2)
        encoder.setCallback { [weak encoder] image, _ in
            output.withLock { $0.append(image.timeStamp) }
            if image.timeStamp == 0, let encoder {
                // Completion processing cannot interleave this reentrant burst
                // on the encoder executor: fill the slots, defer, then replace.
                for id in UInt32(1)...expected {
                    #expect(encoder.encode(frame(buffer, id: id), codecSpecificInfo: nil, frameTypes: []) == 0)
                }
                #expect(encoder.diagnostics.capacityDrops > 0)
                injected.withLock { $0 = true }
            }
            return true
        }
        defer { _ = encoder.release(); encoder.setCallback(nil) }
        #expect(encoder.startEncode(with: settings(width: 5120, height: 2880), numberOfCores: 1) == 0)
        #expect(encoder.encode(frame(buffer, id: 0), codecSpecificInfo: nil, frameTypes: []) == 0)
        #expect(waitUntil { injected.withLock { $0 } })
        // The oracle is the input identity, not the count: a replacement drop
        // and an incoming drop must not be mistaken for the same frame.
        #expect(encoder.diagnostics.capacityDrops > 0)
        let delivered = waitUntil { output.withLock { $0.contains(expected) } }
        #expect(delivered, "Last input must be encoded after the producer stops")
        let ids = output.withLock { $0 }
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
        #expect(encoder.diagnostics.peakInFlightFrames <= slots)
    }
}

func settings(width: Int, height: Int) -> RTCVideoEncoderSettings {
    let value = RTCVideoEncoderSettings()
    value.name = "H265"
    value.width = UInt16(width)
    value.height = UInt16(height)
    value.maxFramerate = 60
    value.startBitrate = 30_000
    value.maxBitrate = 30_000
    value.mode = .screensharing
    return value
}

func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
    #expect(status == kCVReturnSuccess)
    let buffer = try #require(result)
    #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
        let address = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
        memset(address, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

func frame(_ buffer: CVPixelBuffer, id: UInt32) -> RTCVideoFrame {
    let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: Int64(id) * 16_666_667)
    frame.timeStamp = Int32(bitPattern: id)
    return frame
}

func waitUntil(_ predicate: () -> Bool) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    repeat {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    } while ProcessInfo.processInfo.systemUptime < deadline
    return predicate()
}
