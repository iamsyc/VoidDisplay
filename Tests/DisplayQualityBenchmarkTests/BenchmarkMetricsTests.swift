import Foundation
import Testing
@testable import DisplayQualityBenchmark

struct BenchmarkMetricsTests {
    @Test func exactPixelsHaveNoErrorAndDoNotSerializeInfinity() throws {
        let region = QualityRegion(name: "test", x: 0, y: 0, width: 2, height: 1)
        let pixels: [UInt8] = [20, 30, 40, 255, 80, 90, 100, 255]
        let error = try PixelError.measure(reference: pixels, decoded: pixels, width: 2, region: region)
        #expect(error.exact)
        #expect(error.psnrDB == nil)
        #expect(error.edgeMAE == 0)
        #expect(error.badPixelFraction == 0)
    }

    @Test func regionalMetricsExposeThinLineDamageInsteadOfAveragingTheWholeFrame() throws {
        let pixels = [UInt8](repeating: 0, count: 16)
        var changed = pixels
        changed[0] = 30
        changed[1] = 30
        changed[2] = 30
        let error = try PixelError.measure(reference: pixels, decoded: changed, width: 4,
                                           region: .init(name: "line", x: 0, y: 0, width: 2, height: 1))
        #expect(error.samples == 6)
        #expect(error.meanAbsoluteError == 15)
        #expect(error.badPixelFraction == 0.5)
        #expect(error.edgeMAE == 30)
        #expect(try #require(error.psnrDB) > 21)
        #expect(try #require(error.psnrDB) < 22)
        #expect(throws: BenchmarkError.self) {
            try PixelError.measure(reference: pixels, decoded: changed, width: 4,
                                   region: .init(name: "invalid", x: 3, y: 0, width: 2, height: 1))
        }
    }

    @Test func nearestRankPercentilesKeepOutliersAndMissingSamplesExplicit() {
        #expect(percentile([], 0.95) == nil)
        #expect(percentile([2, 1, 100, 3], 0.5) == 2)
        #expect(percentile([2, 1, 100, 3], 0.95) == 100)
    }

    @Test func optionsRejectUnboundedOrUnsupportedExperiments() throws {
        let options = try BenchmarkOptions.parse(["--size", "5k", "--fps", "60", "--seconds", "90", "--warmup", "30"])
        #expect(options.width == 5120)
        #expect(options.height == 2880)
        #expect(options.bitrateKbps == 44236)
        #expect(throws: BenchmarkError.self) { try BenchmarkOptions.parse(["--size", "8k"]) }
        #expect(throws: BenchmarkError.self) { try BenchmarkOptions.parse(["--seconds", "-1"]) }
        #expect(throws: BenchmarkError.self) { try BenchmarkOptions.parse(["--fps"]) }
    }
}

struct HEVCQualityDecoderTests {
    @Test func annexBPreservesEscapedPayloadAndRejectsTruncatedNAL() throws {
        let nals = try HEVCQualityDecoder.splitAnnexB(Data([0, 0, 0, 1, 64, 1, 0, 0, 3, 1, 0, 0, 0, 1, 66, 1, 9]))
        #expect(nals == [Data([64, 1, 0, 0, 3, 1]), Data([66, 1, 9])])
        #expect(throws: BenchmarkError.self) { try HEVCQualityDecoder.splitAnnexB(Data([0, 0, 0, 1, 64])) }
        #expect(throws: BenchmarkError.self) { try HEVCQualityDecoder.splitAnnexB(Data([4, 5, 6])) }
    }
}

struct QualityFixtureTests {
    @Test func everyRegionContainsDetailAndScrollActuallyChangesPixels() throws {
        let fixture = QualityFixture(width: 1920, height: 1080)
        let original = try fixture.pixels(fixture.image(phase: 0))
        let moved = try fixture.pixels(fixture.image(phase: 1))
        for region in fixture.regions {
            var detailPixels = 0
            for y in region.y..<(region.y + region.height) {
                for x in region.x..<(region.x + region.width) {
                    let offset = (y * fixture.width + x) * 4
                    if original[offset] < 220 || original[offset + 1] < 220 || original[offset + 2] < 220 { detailPixels += 1 }
                }
            }
            #expect(Double(detailPixels) / Double(region.width * region.height) > 0.02, "Empty chart region: \(region.name)")
        }
        let scroll = try #require(fixture.regions.last)
        let difference = try PixelError.measure(reference: original, decoded: moved, width: fixture.width, region: scroll)
        #expect(difference.badPixelFraction > 0.02)
    }
}

struct EvidenceDirectoryTests {
    @Test func existingAndPartialEvidenceCannotBeReused() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".ai-tmp/quality-tests/\(UUID().uuidString)")
        try claimEvidenceDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("partial.json")
        try Data("partial evidence".utf8).write(to: artifact)
        #expect(throws: BenchmarkError.self) { try claimEvidenceDirectory(root) }
        #expect(try String(contentsOf: artifact, encoding: .utf8) == "partial evidence")
    }
}
