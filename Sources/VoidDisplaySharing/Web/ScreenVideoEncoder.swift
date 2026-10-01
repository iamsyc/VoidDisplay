import Accelerate
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox
import VoidDisplayObservability

#if canImport(WebRTC)
@preconcurrency import WebRTC

/// The sharing source supplies native NV12 CVPixelBuffers. The hardware encoder
/// submits them asynchronously without frame reordering or queued-frame delay.
package nonisolated final class ScreenVideoEncoder: NSObject, RTCVideoEncoder {
    private struct FrameMetadata {
        let timestamp: UInt32
        let captureTimeMs: Int64
        let rotation: RTCVideoRotation
        let width: Int32
        let height: Int32
        let startedAtMs: Int64
    }

    private struct OutputState: @unchecked Sendable {
        var callback: RTCVideoEncoderCallback?
        var frames: [UInt: FrameMetadata] = [:]
    }

    private let output = Mutex(OutputState())
    // WebRTC serializes the encoder protocol calls; only output callbacks use
    // the mutex. Invalidation drains callbacks before this object is released.
    private var session: VTCompressionSession?
    private var nextFrameID: UInt = 0
    private var needsKeyframe = false
    private var width: Int32 = 0
    private var height: Int32 = 0

    package var resolutionAlignment: Int { 2 }
    package var applyAlignmentToAllSimulcastLayers: Bool { true }
    package var supportsNativeHandle: Bool { true }
    package func implementationName() -> String { "VideoToolbox LowLatency" }
    package func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }

    package func setCallback(_ callback: RTCVideoEncoderCallback?) {
        output.withLock { $0.callback = callback }
    }

    package func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        _ = release()
        width = Int32(settings.width)
        height = Int32(settings.height)
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: width, height: height,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: { refcon, frameRefcon, status, _, sample in
                guard let refcon, let frameRefcon else { return }
                Unmanaged<ScreenVideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
                    .didEncode(frameID: UInt(bitPattern: frameRefcon), status: status, sample: sample)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            AppLog.web.error("H265 low-latency hardware encoder creation failed status=\(status, privacy: .public).")
            _ = release()
            return -1
        }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main_AutoLevel,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 7_200,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 240,
            kVTCompressionPropertyKey_ExpectedFrameRate: settings.maxFramerate,
            kVTCompressionPropertyKey_AverageBitRate: UInt64(settings.startBitrate) * 1_000,
            // AverageBitRate is a soft target. The shared Main-tier contract
            // also requires a hard bitrate/CPB bound before declaring its PTL.
            kVTCompressionPropertyKey_DataRateLimits: [WebRTCHEVCFormat.maxBitrateBps / 8, 1],
        ]
        let configured = VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        let prepared = configured == noErr ? VTCompressionSessionPrepareToEncodeFrames(session) : configured
        guard prepared == noErr else {
            AppLog.web.error("H265 low-latency encoder configuration failed status=\(prepared, privacy: .public).")
            _ = release()
            return -1
        }
        return 0
    }

    package func release() -> Int {
        output.withLock { $0.frames.removeAll() }
        needsKeyframe = false
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
        return 0
    }

    package func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        guard let session else { return -1 }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_AverageBitRate: UInt64(bitrateKbit) * 1_000,
            kVTCompressionPropertyKey_ExpectedFrameRate: framerate,
        ]
        return VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary) == noErr ? 0 : -1
    }

    package func encode(_ frame: RTCVideoFrame, codecSpecificInfo: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        needsKeyframe = needsKeyframe || frameTypes.contains { $0.uintValue == RTCFrameType.videoFrameKey.rawValue }
        // One frame may be encoding while the next is submitted. Dropping a
        // new input when both slots are occupied keeps hardware contention
        // from accumulating an unbounded queue of stale desktop frames.
        guard output.withLock({ $0.frames.count < 2 }) else { return 0 }
        guard let session, let native = frame.buffer as? RTCCVPixelBuffer,
              let pixelBuffer = inputBuffer(native, session: session) else { return -1 }
        nextFrameID += 1
        let frameID = nextFrameID
        let metadata = FrameMetadata(
            timestamp: UInt32(bitPattern: frame.timeStamp), captureTimeMs: frame.timeStampNs / 1_000_000,
            rotation: frame.rotation, width: width, height: height,
            startedAtMs: Int64(ProcessInfo.processInfo.systemUptime * 1_000)
        )
        output.withLock { $0.frames[frameID] = metadata }
        let properties = needsKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: frame.timeStampNs, timescale: 1_000_000_000),
            duration: .invalid, frameProperties: properties,
            sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: frameID), infoFlagsOut: nil
        )
        if status != noErr {
            // A synchronous failure can also invoke the output callback. The
            // dictionary gives both paths one shared completion boundary.
            _ = output.withLock { $0.frames.removeValue(forKey: frameID) }
            AppLog.web.error("H265 low-latency frame encode failed status=\(status, privacy: .public).")
            return -1
        }
        needsKeyframe = false
        return 0
    }

    private func inputBuffer(_ native: RTCCVPixelBuffer, session: VTCompressionSession) -> CVPixelBuffer? {
        guard let pool = VTCompressionSessionGetPixelBufferPool(session) else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        // The hardware encoder retains reference buffers after its callback.
        // Give it an owned buffer so it cannot exhaust ScreenCaptureKit's pool.
        if !native.requiresCropping(), !native.requiresScaling(toWidth: width, height: height) {
            let source = native.pixelBuffer
            guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
            guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let to = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return nil }
                let rows = vImagePixelCount(CVPixelBufferGetHeightOfPlane(buffer, plane))
                var sourcePlane = vImage_Buffer(
                    data: from, height: rows, width: vImagePixelCount(width),
                    rowBytes: CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                )
                var destinationPlane = vImage_Buffer(
                    data: to, height: rows, width: vImagePixelCount(width),
                    rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                )
                guard vImageCopyBuffer(&sourcePlane, &destinationPlane, 1, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
            }
            return buffer
        }
        let count = native.bufferSizeForCroppingAndScaling(toWidth: width, height: height)
        var scratch = [UInt8](repeating: 0, count: Int(count))
        return scratch.withUnsafeMutableBufferPointer {
            native.cropAndScale(to: buffer, withTempBuffer: $0.baseAddress)
        } ? buffer : nil
    }

    private func didEncode(frameID: UInt, status: OSStatus, sample: CMSampleBuffer?) {
        let (metadata, callback) = output.withLock { ($0.frames.removeValue(forKey: frameID), $0.callback) }
        guard let metadata, let callback, status == noErr, let sample,
              let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
        let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true
        var parameterSets: [Data] = []
        var headerLength: Int32 = 0
        var parameterCount = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &parameterCount,
            nalUnitHeaderLengthOut: &headerLength
        ) == noErr else { return }
        if isKeyframe {
            for index in 0..<parameterCount {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                ) == noErr, let pointer else { return }
                parameterSets.append(Data(bytes: pointer, count: size))
            }
        }
        var lengthPrefixed = Data(count: CMBlockBufferGetDataLength(block))
        guard !lengthPrefixed.isEmpty else { return }
        let copied = lengthPrefixed.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        guard copied == noErr,
              let annexB = HEVCAnnexB.convert(lengthPrefixed, headerLength: Int(headerLength), parameterSets: parameterSets) else { return }
        let image = RTCEncodedImage()
        image.buffer = annexB
        image.encodedWidth = metadata.width
        image.encodedHeight = metadata.height
        image.timeStamp = metadata.timestamp
        image.captureTimeMs = metadata.captureTimeMs
        image.rotation = metadata.rotation
        image.frameType = isKeyframe ? .videoFrameKey : .videoFrameDelta
        image.contentType = .screenshare
        image.encodeStartMs = metadata.startedAtMs
        image.encodeFinishMs = Int64(ProcessInfo.processInfo.systemUptime * 1_000)
        let info = ScreenCodecSpecificInfo()
        _ = callback(image, info)
    }
}

// The H.265 bitstream carries VPS/SPS/PPS; the Objective-C callback needs no
// additional codec-specific fields for the negotiated RTP packetizer.
private nonisolated final class ScreenCodecSpecificInfo: NSObject, RTCCodecSpecificInfo {}

package enum HEVCAnnexB {
    package static func convert(_ lengthPrefixed: Data, headerLength: Int, parameterSets: [Data]) -> Data? {
        guard (1...4).contains(headerLength) else { return nil }
        let startCode: [UInt8] = [0, 0, 0, 1]
        var output = Data()
        for parameter in parameterSets {
            guard let parameter = sharedParameterSet(parameter) else { return nil }
            output.append(contentsOf: startCode)
            output.append(parameter)
        }
        var offset = 0
        while offset < lengthPrefixed.count {
            guard lengthPrefixed.count - offset >= headerLength else { return nil }
            var length = 0
            for byte in lengthPrefixed[offset..<(offset + headerLength)] {
                length = (length << 8) | Int(byte)
            }
            offset += headerLength
            guard length > 0, length <= lengthPrefixed.count - offset else { return nil }
            guard let nal = sharedParameterSet(lengthPrefixed[offset..<(offset + length)]) else { return nil }
            output.append(contentsOf: startCode)
            output.append(nal)
            offset += length
        }
        return output.isEmpty ? nil : output
    }

    private static func sharedParameterSet(_ nal: Data) -> Data? {
        guard let first = nal.first else { return nil }
        let type = (first >> 1) & 0x3F
        guard type == 32 || type == 33 else { return nal }
        // The hardware emits High tier even with a Main-tier data-rate cap.
        // Declare the bounded Main Level 6 stream at the existing Annex B
        // boundary. Preserve every field other than general_tier/level_idc.
        let bytes = [UInt8](nal)
        var rbsp: [UInt8] = []
        for index in bytes.indices {
            if index >= 2, bytes[index] == 3, bytes[index - 1] == 0, bytes[index - 2] == 0 { continue }
            rbsp.append(bytes[index])
        }
        let profileOffset = type == 32 ? 6 : 3
        let subLayersOffset = type == 32 ? 3 : 2
        guard rbsp.count > profileOffset + 11,
              (rbsp[subLayersOffset] >> 1) & 7 == 0,
              rbsp[profileOffset] & 0xDF == 1,
              rbsp[profileOffset + 11] <= WebRTCHEVCFormat.level else { return nil }
        rbsp[profileOffset] = 1
        rbsp[profileOffset + 11] = WebRTCHEVCFormat.level
        var output = Data()
        var zeroCount = 0
        for byte in rbsp {
            if zeroCount == 2, byte <= 3 {
                output.append(3)
                zeroCount = 0
            }
            output.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }
        return output
    }
}
#endif
