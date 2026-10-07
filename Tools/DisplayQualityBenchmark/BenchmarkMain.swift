import Darwin
import CryptoKit
import Foundation

struct BenchmarkOptions: Codable, Equatable {
    var size = "4k"
    var fps = 60
    var warmup = 3
    var seconds = 10
    var rounds = 3
    var output = ".ai-tmp/display-quality"
    var width: Int { size == "5k" ? 5120 : (size == "4k" ? 3840 : 1920) }
    var height: Int { size == "5k" ? 2880 : (size == "4k" ? 2160 : 1080) }
    var bitrateKbps: Int { max(2000, Int(Double(width * height * fps) * 0.05 / 1000)) }

    static func parse(_ arguments: [String]) throws -> Self {
        var result = Self()
        guard arguments.count % 2 == 0 else { throw BenchmarkError.failed("Options require values") }
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--size": result.size = value
            case "--fps": result.fps = Int(value) ?? -1
            case "--warmup": result.warmup = Int(value) ?? -1
            case "--seconds": result.seconds = Int(value) ?? -1
            case "--rounds": result.rounds = Int(value) ?? -1
            case "--output": result.output = value
            default: throw BenchmarkError.failed("Unknown option: \(arguments[index])")
            }
        }
        guard ["1080p", "4k", "5k"].contains(result.size), [30, 60].contains(result.fps),
              (0...30).contains(result.warmup), (1...120).contains(result.seconds), (1...5).contains(result.rounds) else {
            throw BenchmarkError.failed("Use size 1080p/4k/5k, FPS 30/60, warmup 0...30, seconds 1...120, rounds 1...5")
        }
        return result
    }
}

struct SlotComparison: Codable {
    let metric: String
    let twoSlotMedian: Double?
    let oneSlotMedian: Double?
    let oneSlotChangePercent: Double?

    init(metric: String, runs: [RunResult], value: (RunResult) -> Double?) {
        self.metric = metric
        twoSlotMedian = percentile(runs.filter { $0.slots == 2 }.compactMap(value), 0.5)
        oneSlotMedian = percentile(runs.filter { $0.slots == 1 }.compactMap(value), 0.5)
        if let baseline = twoSlotMedian, let candidate = oneSlotMedian, baseline > 0 {
            oneSlotChangePercent = (candidate / baseline - 1) * 100
        } else { oneSlotChangePercent = nil }
    }
}

struct BenchmarkReport: Encodable {
    let schemaVersion = 2
    let fixtureVersion = "voiddisplay-chart-v1"
    let measurement = "synthetic-NV12-input-to-encoded-callback; separate-local-decoder-quality"
    let createdAt: Date
    let operatingSystem: String
    let sourceFingerprint: String
    let binarySHA256: String
    let options: BenchmarkOptions
    let runs: [RunResult]
    let comparisons: [SlotComparison]
    let quality: [QualityResult]
    let lastChangeProbe: [String: [String: Bool?]]
    let imageSHA256: [String: String]
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(value).write(to: url, options: .atomic)
}

func fileHash(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

func claimEvidenceDirectory(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard mkdir(directory.path, 0o755) == 0 else {
        throw BenchmarkError.failed("Cannot exclusively create output directory (errno \(errno)); use a fresh path")
    }
}

@main
struct BenchmarkMain {
    static func main() {
        do { try run() } catch {
            FileHandle.standardError.write(Data("Benchmark failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        let options = try BenchmarkOptions.parse(Array(CommandLine.arguments.dropFirst()))
        let directory = URL(fileURLWithPath: options.output, isDirectory: true)
        try claimEvidenceDirectory(directory)
        var completed = false
        defer {
            try? writeJSON(["status": completed ? "completed" : "failed"], to: directory.appendingPathComponent("status.json"))
        }
        let fixture = QualityFixture(width: options.width, height: options.height)
        let buffers = try (0..<8).map { try fixture.buffer(for: fixture.image(phase: $0)) }
        var runs: [RunResult] = []
        for round in 1...options.rounds {
            for slots in round % 2 == 1 ? [2, 1] : [1, 2] {
                print("Round \(round)/\(options.rounds), \(options.size)@\(options.fps), \(slots) slot(s)")
                let probe = try EncoderProbe(width: options.width, height: options.height, fps: options.fps, bitrateKbps: options.bitrateKbps, slots: slots)
                let result = try probe.run(buffers: buffers, fps: options.fps, warmup: options.warmup,
                                           seconds: options.seconds, round: round, slots: slots)
                try writeJSON(result, to: directory.appendingPathComponent("round-\(round)-slots-\(slots).json"))
                if let failure = result.failureReason { throw BenchmarkError.failed(failure) }
                runs.append(result)
                print("  callback P95 \(result.inputToCallbackMs.p95 ?? 0) ms, output \(result.outputFPS) fps, capacity drops \(result.diagnostics.capacityDrops)")
            }
        }
        var lastChange: [String: [String: Bool?]] = [:]
        for slots in [2, 1] {
            let probe = try EncoderProbe(width: options.width, height: options.height, fps: options.fps, bitrateKbps: options.bitrateKbps, slots: slots)
            defer {
                try? writeJSON(probe.snapshot(), to: directory.appendingPathComponent("last-change-slots-\(slots).json"))
                try? writeJSON(probe.encoder.diagnostics, to: directory.appendingPathComponent("last-change-slots-\(slots)-diagnostics.json"))
            }
            lastChange[String(slots)] = try probe.lastChangeProbe(buffers: buffers)
        }
        print("Measuring reconstruction quality in a separate serial decode pass")
        let quality = try measureQuality(fixture: fixture, fps: options.fps, bitrateKbps: options.bitrateKbps, directory: directory)
        var images: [String: String] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "png" {
            images[file.lastPathComponent] = try fileHash(file)
        }
        let report = BenchmarkReport(createdAt: Date(), operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                                     sourceFingerprint: ProcessInfo.processInfo.environment["VOIDDISPLAY_BENCHMARK_SOURCE_FINGERPRINT"] ?? "unrecorded-direct-invocation",
                                     binarySHA256: try fileHash(URL(fileURLWithPath: CommandLine.arguments[0])), options: options, runs: runs,
                                     comparisons: [
                                        SlotComparison(metric: "inputToCallbackP95Ms", runs: runs, value: { $0.inputToCallbackMs.p95 }),
                                        SlotComparison(metric: "outputFPS", runs: runs, value: { $0.outputFPS }),
                                        SlotComparison(metric: "bitrateBps", runs: runs, value: { $0.bitrateBps })
                                     ], quality: quality, lastChangeProbe: lastChange, imageSHA256: images)
        try writeJSON(report, to: directory.appendingPathComponent("benchmark.json"))
        completed = true
        print("Evidence: \(directory.appendingPathComponent("benchmark.json").path)")
        print("Encoder-only experiment; no capture, transport, browser presentation or photon measurement.")
    }
}
