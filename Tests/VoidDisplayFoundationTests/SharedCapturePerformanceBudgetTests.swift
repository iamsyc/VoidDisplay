@testable import VoidDisplayFoundation
import Testing

struct SharedCapturePerformanceBudgetTests {
    @Test func performanceModesMapToExpectedPixelBudgets() {
        #expect(SharedCapturePerformanceBudget(performanceMode: .automatic) == SharedCapturePerformanceBudget(
            framesPerSecond: 60,
            pixelBudgetPerSecond: 221_184_000
        ))
        #expect(SharedCapturePerformanceBudget(performanceMode: .smooth) == SharedCapturePerformanceBudget(
            framesPerSecond: 60,
            pixelBudgetPerSecond: nil
        ))
        #expect(SharedCapturePerformanceBudget(performanceMode: .powerEfficient) == SharedCapturePerformanceBudget(
            framesPerSecond: 30,
            pixelBudgetPerSecond: 62_208_000
        ))
    }

    @Test func pixelBudgetComputesEvenDimensionsWithoutUpscaling() {
        let automaticBudget = SharedCapturePerformanceBudget(performanceMode: .automatic)

        #expect(
            automaticBudget.captureDimensions(
                for: CapturePixelDimensions(width: 3_840, height: 2_160)
            ) == CapturePixelDimensions(width: 2_560, height: 1_440)
        )
        #expect(
            automaticBudget.captureDimensions(
                for: CapturePixelDimensions(width: 1_920, height: 1_080)
            ) == CapturePixelDimensions(width: 1_920, height: 1_080)
        )
        #expect(
            automaticBudget.captureDimensions(
                for: CapturePixelDimensions(width: 3_440, height: 1_440)
            ) == CapturePixelDimensions(width: 2_968, height: 1_242)
        )
        #expect(
            automaticBudget.captureDimensions(
                for: CapturePixelDimensions(width: 2_161, height: 3_841)
            ) == CapturePixelDimensions(width: 1_440, height: 2_560)
        )
    }

    @Test func smoothBudgetKeepsSourceDimensions() {
        let smoothBudget = SharedCapturePerformanceBudget(performanceMode: .smooth)

        #expect(
            smoothBudget.captureDimensions(
                for: CapturePixelDimensions(width: 3_840, height: 2_160)
            ) == CapturePixelDimensions(width: 3_840, height: 2_160)
        )
    }
}
