import CoreVideo
import Foundation
import Synchronization
import VoidDisplaySharing
@preconcurrency import WebRTC

func uptimeMS() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

struct RawFrame: Codable, Sendable {
    let id: UInt32
    let scene: String
    let measured: Bool
    let submittedAtMs: Double
    let latenessMs: Double
    var submissionMs: Double?
    var inputToCallbackMs: Double?
    var encoderReportedMs: Int64?
    var bytes: Int?
    var keyframe: Bool?
    var status: Int?
}

struct TimingSummary: Codable {
    let count: Int
    let p50: Double?
    let p95: Double?
    let p99: Double?
    init(_ values: [Double]) {
        count = values.count
        p50 = percentile(values, 0.5)
        p95 = percentile(values, 0.95)
        p99 = percentile(values, 0.99)
    }
}

struct RunResult: Codable {
    let failureReason: String?
    let round: Int
    let slots: Int
    let elapsedSeconds: Double
    let outputFPS: Double
    let bitrateBps: Double
    let schedulerMissedFrames: Int
    let inputToCallbackMs: TimingSummary
    let submissionMs: TimingSummary
    let diagnostics: ScreenEncoderDiagnostics
    let rawFrames: [RawFrame]
}

final class EncoderProbe: @unchecked Sendable {
    let encoder: ScreenVideoEncoder
    private let frames = Mutex<[UInt32: RawFrame]>([:])
    private var nextID: UInt32 = 0

    init(width: Int, height: Int, fps: Int, bitrateKbps: Int, slots: Int) throws {
        encoder = ScreenVideoEncoder(maximumInFlightFrames: slots)
        encoder.setCallback { [weak self] image, _ in
            guard let self else { return false }
            let completed = uptimeMS()
            self.frames.withLock {
                guard var frame = $0[image.timeStamp] else { return }
                frame.inputToCallbackMs = completed - frame.submittedAtMs
                frame.encoderReportedMs = image.encodeFinishMs - image.encodeStartMs
                frame.bytes = image.buffer.count
                frame.keyframe = image.frameType == .videoFrameKey
                $0[image.timeStamp] = frame
            }
            return true
        }
        guard encoder.startEncode(with: encoderSettings(width: width, height: height, fps: fps, bitrateKbps: bitrateKbps), numberOfCores: 1) == 0 else {
            throw BenchmarkError.failed("Hardware HEVC encoder unavailable")
        }
    }

    deinit {
        _ = encoder.release()
        encoder.setCallback(nil)
    }

    @discardableResult
    func submit(_ buffer: CVPixelBuffer, scene: String, measured: Bool, scheduled: Double, keyframe: Bool = false) -> UInt32 {
        nextID += 1
        let id = nextID
        let now = uptimeMS()
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: Int64(now * 1_000_000))
        frame.timeStamp = Int32(bitPattern: id)
        frames.withLock { $0[id] = RawFrame(id: id, scene: scene, measured: measured, submittedAtMs: now, latenessMs: max(0, now - scheduled)) }
        let status = encoder.encode(frame, codecSpecificInfo: nil, frameTypes: keyframe ? [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)] : [])
        let end = uptimeMS()
        frames.withLock {
            $0[id]?.submissionMs = end - now
            $0[id]?.status = status
        }
        return id
    }

    func waitForDrain() throws {
        let deadline = uptimeMS() + 5_000
        while true {
            let counts = encoder.diagnostics
            if counts.pendingFrames == 0 && counts.submittedFrames == counts.outputFrames + counts.compressionFailures + counts.hardwareDrops + counts.outputFailures + counts.releasedFrames { break }
            if uptimeMS() > deadline { throw BenchmarkError.failed("Encoder drain timed out") }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    func snapshot() -> [RawFrame] { frames.withLock { $0.values.sorted { $0.id < $1.id } } }

    func run(buffers: [CVPixelBuffer], fps: Int, warmup: Int, seconds: Int, round: Int, slots: Int) throws -> RunResult {
        let start = uptimeMS()
        let step = 1000.0 / Double(fps)
        let total = (warmup + seconds) * fps
        var index = 0
        var missed = 0
        while index < total {
            let scheduled = start + Double(index) * step
            let remaining = scheduled - uptimeMS()
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining / 1000) }
            let lateFrames = max(0, Int((uptimeMS() - scheduled) / step))
            if lateFrames > 0 {
                missed += min(lateFrames, total - index)
                index += lateFrames
                if index >= total { break }
            }
            let measuredIndex = index - warmup * fps
            let measured = measuredIndex >= 0
            let scrolling = !measured || (measuredIndex >= seconds * fps / 3 && measuredIndex < seconds * fps * 2 / 3)
            let changed = measured && measuredIndex >= seconds * fps * 2 / 3
            let phase = scrolling ? index % buffers.count : (changed ? buffers.count - 1 : 0)
            submit(buffers[phase], scene: scrolling ? "scroll" : (changed ? "change-and-hold" : "static"), measured: measured,
                   scheduled: start + Double(index) * step, keyframe: index == 0)
            index += 1
        }
        // Keep the nominal measurement window, then include tail drain separately.
        let remaining = start + Double(warmup + seconds) * 1000 - uptimeMS()
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining / 1000) }
        var failureReason: String?
        do { try waitForDrain() } catch { failureReason = String(describing: error) }
        let all = snapshot()
        let measured = all.filter(\.measured)
        let delivered = measured.filter { $0.inputToCallbackMs != nil }
        let diagnostics = encoder.diagnostics
        if diagnostics.inputFailures > 0 || diagnostics.compressionFailures > 0 || diagnostics.outputFailures > 0 || delivered.isEmpty {
            failureReason = failureReason ?? "Invalid encoder output: \(diagnostics)"
        }
        return RunResult(failureReason: failureReason, round: round, slots: slots, elapsedSeconds: (uptimeMS() - start) / 1000,
                         outputFPS: Double(delivered.count) / Double(seconds),
                         bitrateBps: Double(delivered.reduce(0) { $0 + ($1.bytes ?? 0) } * 8) / Double(seconds),
                         schedulerMissedFrames: missed,
                         inputToCallbackMs: TimingSummary(delivered.compactMap(\.inputToCallbackMs)),
                         submissionMs: TimingSummary(measured.compactMap(\.submissionMs)),
                         diagnostics: diagnostics, rawFrames: all)
    }

    func lastChangeProbe(buffers: [CVPixelBuffer]) throws -> [String: Bool?] {
        try waitForDrain()
        var deferredID: UInt32?
        // Stop the producer immediately after it hits capacity. The exact
        // incoming ID must survive without another producer callback.
        for index in 0..<100 {
            let before = encoder.diagnostics.deferredFrames
            let id = submit(buffers[index % buffers.count], scene: "last-change", measured: false, scheduled: uptimeMS(), keyframe: true)
            if encoder.diagnostics.deferredFrames > before { deferredID = id; break }
        }
        try waitForDrain()
        Thread.sleep(forTimeInterval: 0.25)
        let recovered = deferredID.flatMap { id in snapshot().first { $0.id == id && $0.inputToCallbackMs != nil } }
        return ["forcedDeferral": deferredID != nil,
                "lastChangeRecoveredWithoutNewInput": deferredID == nil ? nil : recovered != nil,
                "recoveredInputIsKeyframe": recovered?.keyframe,
                "drained": encoder.diagnostics.pendingFrames == 0 && encoder.diagnostics.inFlightFrames == 0]
    }
}

func encoderSettings(width: Int, height: Int, fps: Int, bitrateKbps: Int) -> RTCVideoEncoderSettings {
    let settings = RTCVideoEncoderSettings()
    settings.name = "H265"
    settings.width = UInt16(width)
    settings.height = UInt16(height)
    settings.maxFramerate = UInt32(fps)
    settings.startBitrate = UInt32(bitrateKbps)
    settings.maxBitrate = UInt32(bitrateKbps)
    settings.mode = .screensharing
    return settings
}

struct QualityResult: Codable {
    let scene: String
    let region: QualityRegion
    let sourceToNV12: PixelError
    let sourceToDecoded: PixelError
    let nv12ToDecoded: PixelError
}

/// Quality is a separate serial pass so decode, readback and metric computation
/// cannot contaminate the encoding latency samples.
func measureQuality(fixture: QualityFixture, fps: Int, bitrateKbps: Int, directory: URL) throws -> [QualityResult] {
    let decoder = HEVCQualityDecoder()
    let encoder = ScreenVideoEncoder()
    encoder.setCallback { image, _ in decoder.decode(image) }
    defer {
        _ = encoder.release()
        encoder.setCallback(nil)
    }
    guard encoder.startEncode(with: encoderSettings(width: fixture.width, height: fixture.height, fps: fps, bitrateKbps: bitrateKbps), numberOfCores: 1) == 0 else {
        throw BenchmarkError.failed("Quality encoder unavailable")
    }
    var results: [QualityResult] = []
    for (index, phase) in [0, 0, 1, 2, 3, 4, 5, 6, 7, 7].enumerated() {
        let scene = index == 0 ? "first-frame" : (index == 8 ? "first-change" : (index == 9 ? "held-change" : "scroll"))
        let image = try fixture.image(phase: phase)
        let buffer = try fixture.buffer(for: image)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0,
                                  timeStampNs: Int64(index + 1) * 1_000_000_000 / Int64(fps))
        frame.timeStamp = Int32(index + 1)
        guard encoder.encode(frame, codecSpecificInfo: nil, frameTypes: index == 0 ? [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)] : []) == 0 else {
            throw BenchmarkError.failed("Quality encode failed for frame \(index)")
        }
        let decoded = try decoder.takeFrame(expectedID: UInt32(index + 1))
        guard [0, 7, 8, 9].contains(index) else { continue }
        let decodedImage = try fixture.image(from: decoded)
        let source = try fixture.pixels(image)
        let input = try fixture.pixels(fixture.image(from: buffer))
        let actual = try fixture.pixels(decodedImage)
        for region in fixture.regions {
            results.append(QualityResult(scene: scene, region: region,
                                         sourceToNV12: try PixelError.measure(reference: source, decoded: input, width: fixture.width, region: region),
                                         sourceToDecoded: try PixelError.measure(reference: source, decoded: actual, width: fixture.width, region: region),
                                         nv12ToDecoded: try PixelError.measure(reference: input, decoded: actual, width: fixture.width, region: region)))
        }
        try fixture.save(image, to: directory.appendingPathComponent("\(scene)-reference.png"))
        try fixture.save(decodedImage, to: directory.appendingPathComponent("\(scene)-decoded.png"))
    }
    return results
}
