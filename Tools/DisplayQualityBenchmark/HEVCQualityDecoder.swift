import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox
@preconcurrency import WebRTC

private struct DecoderOutput: @unchecked Sendable {
    var buffer: CVPixelBuffer?
    var status: OSStatus = noErr
    var frameID: Int64?
}

/// Decodes the exact Annex B bytes delivered to WebRTC by ScreenVideoEncoder.
/// It is only used by the offline quality pass; never part of product transport.
final class HEVCQualityDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private let output = Mutex(DecoderOutput())
    private let completed = DispatchSemaphore(value: 0)

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    func decode(_ image: RTCEncodedImage) -> Bool {
        do {
            let nals = try Self.splitAnnexB(image.buffer)
            if format == nil {
                let parameters = nals.filter { [32, 33, 34].contains(Int(($0[0] >> 1) & 0x3F)) }.map { $0 as NSData }
                guard parameters.count == 3 else { throw BenchmarkError.failed("Missing HEVC parameter sets") }
                let pointers = parameters.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
                let sizes = parameters.map(\.length)
                let status = pointers.withUnsafeBufferPointer { pointerStorage in
                    sizes.withUnsafeBufferPointer { sizeStorage in
                        CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: nil, parameterSetCount: parameters.count,
                            parameterSetPointers: pointerStorage.baseAddress!, parameterSetSizes: sizeStorage.baseAddress!,
                            nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format
                        )
                    }
                }
                guard status == noErr, let format else { throw BenchmarkError.failed("Invalid HEVC format: \(status)") }
                var callback = VTDecompressionOutputCallbackRecord(
                    decompressionOutputCallback: { reference, _, status, _, buffer, presentationTime, _ in
                        guard let reference else { return }
                        let decoder = Unmanaged<HEVCQualityDecoder>.fromOpaque(reference).takeUnretainedValue()
                        decoder.output.withLock { $0 = DecoderOutput(buffer: buffer, status: status, frameID: presentationTime.value) }
                        decoder.completed.signal()
                    }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
                )
                let attributes: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferIOSurfacePropertiesKey: [:]
                ]
                let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                                                            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
                                                            outputCallback: &callback, decompressionSessionOut: &session)
                guard created == noErr else { throw BenchmarkError.failed("Decoder creation failed: \(created)") }
            }
            guard let session, let format else { throw BenchmarkError.failed("Decoder not ready") }
            var bytes = Data()
            for nal in nals {
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
                bytes.append(nal)
            }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count,
                                                    blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                    dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr,
                  let block else { throw BenchmarkError.failed("Cannot allocate encoded block") }
            let copied = bytes.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count)
            }
            var timing = CMSampleTimingInfo(duration: .invalid,
                                           presentationTimeStamp: CMTime(value: Int64(image.timeStamp), timescale: 90_000), decodeTimeStamp: .invalid)
            var size = bytes.count
            var sample: CMSampleBuffer?
            guard copied == noErr,
                  CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                                            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
                  let sample else { throw BenchmarkError.failed("Cannot create HEVC sample") }
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
            guard status == noErr else { throw BenchmarkError.failed("Decode submission failed: \(status)") }
            return true
        } catch {
            output.withLock { $0 = DecoderOutput(status: -1) }
            completed.signal()
            return false
        }
    }

    func takeFrame(expectedID: UInt32) throws -> CVPixelBuffer {
        guard completed.wait(timeout: .now() + 5) == .success,
              let buffer = output.withLock({ $0.status == noErr && $0.frameID == Int64(expectedID) ? $0.buffer : nil }) else {
            throw BenchmarkError.failed("HEVC decode failed or timed out")
        }
        output.withLock { $0 = DecoderOutput() }
        return buffer
    }

    static func splitAnnexB(_ data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        var starts: [Int] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append(index)
                index += 4
            } else { index += 1 }
        }
        guard starts.first == 0 else { throw BenchmarkError.failed("Expected encoder's four-byte Annex B start codes") }
        return try starts.enumerated().map { index, start in
            let end = index + 1 < starts.count ? starts[index + 1] : bytes.count
            guard end >= start + 6 else { throw BenchmarkError.failed("Truncated HEVC NAL") }
            return Data(bytes[(start + 4)..<end])
        }
    }
}
