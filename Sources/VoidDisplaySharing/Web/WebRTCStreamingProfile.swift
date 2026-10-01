import CoreVideo
import Foundation
import Network
import Synchronization
import VoidDisplayFoundation
import VoidDisplayObservability

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif
package enum WebRTCVideoCodec: String, CaseIterable, Sendable {
    case h265

    package var logName: String {
        switch self {
        case .h265:
            "H265"
        }
    }
}

// HEVC Main profile, Main tier, Level 6; ITU-T H.265 Annex A.
package enum WebRTCHEVCFormat {
    package static let level: UInt8 = 180
    package static let maxPicturePixels: Int64 = 35_651_584
    package static let maxPixelsPerSecond: Int64 = 1_069_547_520
    package static let maxBitrateBps = 60_000_000
    package static let sdpParameters = [
        "profile-id": "1", "tier-flag": "0", "level-id": String(level), "tx-mode": "SRST",
    ]
}

package struct WebRTCStreamingProfile: Sendable, Equatable {
    private static let h265BitsPerPixel: Double = 0.05

    package let performanceMode: CapturePerformanceMode
    package let sourceVideoSpec: SourceVideoSpec
    package let framesPerSecond: Int
    package let minBitrateBps: Int
    package let maxBitrateBps: Int
    package let pixelBudgetPerSecond: Int64?

    package init(
        performanceMode: CapturePerformanceMode,
        sourceVideoSpec: SourceVideoSpec,
        framesPerSecond: Int,
        pixelBudgetPerSecond: Int64?
    ) {
        self.performanceMode = performanceMode
        self.sourceVideoSpec = sourceVideoSpec
        self.framesPerSecond = max(1, framesPerSecond)
        self.pixelBudgetPerSecond = pixelBudgetPerSecond
        let outputDimensions = Self.outputDimensions(
            forWidth: Int32(sourceVideoSpec.dimensions.width),
            height: Int32(sourceVideoSpec.dimensions.height),
            framesPerSecond: self.framesPerSecond,
            pixelBudgetPerSecond: pixelBudgetPerSecond
        )
        let maxBitrateBps = Self.targetMaxBitrateBps(
            dimensions: CapturePixelDimensions(width: Int(outputDimensions.width), height: Int(outputDimensions.height)),
            framesPerSecond: self.framesPerSecond
        )
        self.maxBitrateBps = maxBitrateBps
        self.minBitrateBps = Self.targetMinBitrateBps(maxBitrateBps: maxBitrateBps)
    }

    package init(
        performanceMode: CapturePerformanceMode,
        sourceVideoSpec: SourceVideoSpec = .defaultShared
    ) {
        let budget = SharedCapturePerformanceBudget(performanceMode: performanceMode)
        let sourceFramesPerSecond = sourceVideoSpec.framesPerSecond
        switch performanceMode {
        case .automatic:
            self.init(
                performanceMode: performanceMode,
                sourceVideoSpec: sourceVideoSpec,
                framesPerSecond: sourceFramesPerSecond,
                pixelBudgetPerSecond: nil
            )
        case .smooth:
            self.init(
                performanceMode: performanceMode,
                sourceVideoSpec: sourceVideoSpec,
                framesPerSecond: sourceFramesPerSecond,
                pixelBudgetPerSecond: nil
            )
        case .powerEfficient:
            self.init(
                performanceMode: performanceMode,
                sourceVideoSpec: sourceVideoSpec,
                framesPerSecond: min(sourceFramesPerSecond, budget.framesPerSecond),
                pixelBudgetPerSecond: SharedCapturePerformanceBudget.powerEfficientPixelBudgetPerSecond
            )
        }
    }

    package func bitrateLimits(
        for codec: WebRTCVideoCodec,
        outputWidth: Int32,
        outputHeight: Int32
    ) -> (minBitrateBps: Int, maxBitrateBps: Int) {
        let maxBitrateBps = Self.targetMaxBitrateBps(
            dimensions: CapturePixelDimensions(width: Int(outputWidth), height: Int(outputHeight)),
            framesPerSecond: framesPerSecond(for: codec)
        )
        return (
            minBitrateBps: Self.targetMinBitrateBps(maxBitrateBps: maxBitrateBps),
            maxBitrateBps: maxBitrateBps
        )
    }

    package func outputDimensions(
        for codec: WebRTCVideoCodec,
        width: Int32,
        height: Int32
    ) -> (width: Int32, height: Int32) {
        Self.outputDimensions(
            forWidth: width,
            height: height,
            framesPerSecond: framesPerSecond(for: codec),
            pixelBudgetPerSecond: pixelBudgetPerSecond(for: codec)
        )
    }

    package func outputDimensions(forWidth width: Int32, height: Int32) -> (width: Int32, height: Int32) {
        Self.outputDimensions(
            forWidth: width,
            height: height,
            framesPerSecond: framesPerSecond,
            pixelBudgetPerSecond: pixelBudgetPerSecond
        )
    }

    package func framesPerSecond(for codec: WebRTCVideoCodec) -> Int {
        framesPerSecond
    }

    package func outputVideoSpec(for codec: WebRTCVideoCodec) -> SourceVideoSpec {
        let sourceDimensions = sourceVideoSpec.dimensions
        let outputDimensions = outputDimensions(
            for: codec,
            width: Int32(sourceDimensions.width),
            height: Int32(sourceDimensions.height)
        )
        return SourceVideoSpec(
            width: Int(outputDimensions.width),
            height: Int(outputDimensions.height),
            framesPerSecond: framesPerSecond(for: codec)
        )
    }

    private func pixelBudgetPerSecond(for codec: WebRTCVideoCodec) -> Int64? {
        pixelBudgetPerSecond
    }

    private static func outputDimensions(
        forWidth width: Int32,
        height: Int32,
        framesPerSecond: Int,
        pixelBudgetPerSecond: Int64?
    ) -> (width: Int32, height: Int32) {
        guard width > 0, height > 0 else {
            return (width, height)
        }

        let budget = SharedCapturePerformanceBudget(
            framesPerSecond: framesPerSecond,
            pixelBudgetPerSecond: pixelBudgetPerSecond
        )
        var dimensions = budget.captureDimensions(
            for: CapturePixelDimensions(width: Int(width), height: Int(height))
        )
        // VideoToolbox's AutoLevel accounts for padded coded dimensions. For
        // example, 4222x4222 at 60 fps is coded as 4224x4224 and needs Level 6.1.
        let codedDimensions = CapturePixelDimensions(
            width: (dimensions.width + 15) / 16 * 16,
            height: (dimensions.height + 15) / 16 * 16
        )
        let codecFrameBudget = min(WebRTCHEVCFormat.maxPicturePixels, WebRTCHEVCFormat.maxPixelsPerSecond / Int64(framesPerSecond))
        if codedDimensions.pixelCount > codecFrameBudget {
            let constrained = codedDimensions.constrained(toFramePixelBudget: codecFrameBudget)
            dimensions = CapturePixelDimensions(
                width: max(16, constrained.width / 16 * 16),
                height: max(16, constrained.height / 16 * 16)
            )
        }
        return (
            width: Int32(dimensions.width),
            height: Int32(dimensions.height)
        )
    }

    private static func targetMaxBitrateBps(
        dimensions: CapturePixelDimensions,
        framesPerSecond: Int
    ) -> Int {
        let pixelRate = Double(dimensions.pixelCount) * Double(max(1, framesPerSecond))
        let target = Int((pixelRate * h265BitsPerPixel).rounded())
        return max(2_000_000, target)
    }

    private static func targetMinBitrateBps(maxBitrateBps: Int) -> Int {
        max(1_500_000, maxBitrateBps / 4)
    }
}
