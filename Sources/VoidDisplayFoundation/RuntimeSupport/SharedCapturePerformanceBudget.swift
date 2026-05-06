import Foundation

package nonisolated struct CapturePixelDimensions: Sendable, Equatable {
    package static let defaultShared = CapturePixelDimensions(width: 1_920, height: 1_080)

    package let width: Int
    package let height: Int

    package init(width: Int, height: Int) {
        self.width = Self.evenDimension(width)
        self.height = Self.evenDimension(height)
    }

    package var pixelCount: Int64 {
        Int64(width) * Int64(height)
    }

    package func constrained(toFramePixelBudget framePixelBudget: Int64?) -> CapturePixelDimensions {
        guard let framePixelBudget,
              framePixelBudget >= 4,
              pixelCount > framePixelBudget else {
            return self
        }

        let scale = sqrt(Double(framePixelBudget) / Double(pixelCount))
        var constrained = CapturePixelDimensions(
            width: Self.roundedEvenDimension(Double(width) * scale),
            height: Self.roundedEvenDimension(Double(height) * scale)
        )

        while constrained.pixelCount > framePixelBudget {
            if constrained.width >= constrained.height {
                constrained = CapturePixelDimensions(
                    width: constrained.width - 2,
                    height: constrained.height
                )
            } else {
                constrained = CapturePixelDimensions(
                    width: constrained.width,
                    height: constrained.height - 2
                )
            }
        }

        return constrained
    }

    private static func roundedEvenDimension(_ value: Double) -> Int {
        evenDimension(Int(value.rounded()))
    }

    private static func evenDimension(_ value: Int) -> Int {
        let dimension = max(2, value)
        if dimension.isMultiple(of: 2) {
            return dimension
        }
        return dimension - 1
    }
}

package nonisolated struct SharedCapturePerformanceBudget: Sendable, Equatable {
    package static let automaticPixelBudgetPerSecond: Int64 = 221_184_000
    package static let powerEfficientPixelBudgetPerSecond: Int64 = 62_208_000

    package let framesPerSecond: Int
    package let pixelBudgetPerSecond: Int64?

    package init(
        framesPerSecond: Int,
        pixelBudgetPerSecond: Int64?
    ) {
        self.framesPerSecond = max(1, framesPerSecond)
        self.pixelBudgetPerSecond = pixelBudgetPerSecond
    }

    package init(performanceMode: CapturePerformanceMode) {
        switch performanceMode {
        case .automatic:
            self.init(
                framesPerSecond: 60,
                pixelBudgetPerSecond: Self.automaticPixelBudgetPerSecond
            )
        case .smooth:
            self.init(
                framesPerSecond: 60,
                pixelBudgetPerSecond: nil
            )
        case .powerEfficient:
            self.init(
                framesPerSecond: 30,
                pixelBudgetPerSecond: Self.powerEfficientPixelBudgetPerSecond
            )
        }
    }

    package var framePixelBudget: Int64? {
        pixelBudgetPerSecond.map { $0 / Int64(framesPerSecond) }
    }

    package func captureDimensions(for sourceDimensions: CapturePixelDimensions) -> CapturePixelDimensions {
        sourceDimensions.constrained(toFramePixelBudget: framePixelBudget)
    }
}
