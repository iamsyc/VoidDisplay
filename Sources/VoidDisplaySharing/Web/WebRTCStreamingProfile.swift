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
    case av1

    package var logName: String {
        switch self {
        case .av1:
            "AV1"
        }
    }
}

package struct WebRTCStreamingProfile: Sendable, Equatable {
    private static let av1SourceBitsPerPixel: Double = 0.10
    private static let av1PowerEfficientBitsPerPixel: Double = 0.05

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
        let sourceDimensions = sourceVideoSpec.dimensions
        let maxBitrateBps = Self.targetMaxBitrateBps(
            for: .av1,
            dimensions: sourceDimensions,
            framesPerSecond: self.framesPerSecond,
            performanceMode: performanceMode
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
            for: codec,
            dimensions: CapturePixelDimensions(width: Int(outputWidth), height: Int(outputHeight)),
            framesPerSecond: framesPerSecond(for: codec),
            performanceMode: performanceMode
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
        outputDimensions(
            forWidth: width,
            height: height,
            framesPerSecond: framesPerSecond(for: codec),
            pixelBudgetPerSecond: pixelBudgetPerSecond(for: codec)
        )
    }

    package func outputDimensions(forWidth width: Int32, height: Int32) -> (width: Int32, height: Int32) {
        outputDimensions(
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

    private func outputDimensions(
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
        let dimensions = budget.captureDimensions(
            for: CapturePixelDimensions(width: Int(width), height: Int(height))
        )
        return (
            width: Int32(dimensions.width),
            height: Int32(dimensions.height)
        )
    }

    private static func targetMaxBitrateBps(
        for codec: WebRTCVideoCodec,
        dimensions: CapturePixelDimensions,
        framesPerSecond: Int,
        performanceMode: CapturePerformanceMode
    ) -> Int {
        let pixelRate = Double(dimensions.pixelCount) * Double(max(1, framesPerSecond))
        let bitsPerPixel: Double = switch (codec, performanceMode) {
        case (.av1, .powerEfficient):
            av1PowerEfficientBitsPerPixel
        case (.av1, _):
            av1SourceBitsPerPixel
        }
        let target = Int((pixelRate * bitsPerPixel).rounded())
        return max(2_000_000, target)
    }

    private static func targetMinBitrateBps(maxBitrateBps: Int) -> Int {
        max(1_500_000, maxBitrateBps / 4)
    }
}
