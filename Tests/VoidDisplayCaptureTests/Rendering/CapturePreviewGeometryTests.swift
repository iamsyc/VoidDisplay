@testable import VoidDisplayCapture
@testable import VoidDisplayFoundation
import CoreGraphics
import Testing

@Suite(.serialized)
struct CapturePreviewGeometryTests {
    @Test func parseResolutionAcceptsCommonSeparators() {
        #expect(CapturePreviewGeometry.parseResolution("2560 × 1600") == CGSize(width: 2560, height: 1600))
        #expect(CapturePreviewGeometry.parseResolution("1920x1080") == CGSize(width: 1920, height: 1080))
        #expect(CapturePreviewGeometry.parseResolution("3440*1440") == CGSize(width: 3440, height: 1440))
    }

    @Test func preferredAspectPrefersResolutionTextAndFallsBackToFrame() {
        #expect(
            CapturePreviewGeometry.preferredAspect(
                resolutionText: "3008 x 1692",
                framePixelSize: CGSize(width: 1920, height: 1080)
            ) == CGSize(width: 3008, height: 1692)
        )
        #expect(
            CapturePreviewGeometry.preferredAspect(
                resolutionText: "bad-value",
                framePixelSize: CGSize(width: 1920, height: 1080)
            ) == CGSize(width: 1920, height: 1080)
        )
    }

    @Test func nativeFrameSizeInPointsUsesScaleFactor() {
        let size = CapturePreviewGeometry.nativeFrameSizeInPoints(
            framePixelSize: CGSize(width: 2560, height: 1600),
            scaleFactor: 2,
            fallbackAspect: CGSize(width: 16, height: 10)
        )
        #expect(size == CGSize(width: 1280, height: 800))
    }

    @Test func nativeFrameSizeInPointsFallsBackToAspectWhenFrameMissing() {
        let size = CapturePreviewGeometry.nativeFrameSizeInPoints(
            framePixelSize: .zero,
            scaleFactor: 2,
            fallbackAspect: CGSize(width: 3008, height: 1692)
        )
        #expect(size == CGSize(width: 3008, height: 1692))
    }

    @Test func initialContentSizeRespectsTargetWidthOverrideAndInsets() {
        let size = CapturePreviewGeometry.initialContentSize(
            input: .init(
                aspect: CGSize(width: 2560, height: 1600),
                framePixelSize: .zero,
                targetContentWidth: 860,
                visibleFrameSize: CGSize(width: 1600, height: 1000),
                chromeSize: CGSize(width: 40, height: 60),
                layoutInsetSize: CGSize(width: 12, height: 8),
                scaleFactor: 2
            )
        )

        #expect(size?.width == 872)
        #expect(approximatelyEqual(size?.height, 545.5, tolerance: 0.01))
    }

    @Test func initialContentSizeClampsToVisibleBounds() {
        let size = CapturePreviewGeometry.initialContentSize(
            input: .init(
                aspect: CGSize(width: 16, height: 9),
                framePixelSize: .zero,
                targetContentWidth: 1800,
                visibleFrameSize: CGSize(width: 1000, height: 700),
                chromeSize: CGSize(width: 40, height: 60),
                layoutInsetSize: CGSize(width: 0, height: 0),
                scaleFactor: 2
            )
        )

        #expect(approximatelyEqual(size?.width, 944, tolerance: 0.01))
        #expect(approximatelyEqual(size?.height, 531, tolerance: 0.01))
    }

    @Test func aspectLockedContentSizeKeepsRatioAndInsets() {
        let size = CapturePreviewGeometry.aspectLockedContentSize(
            aspect: CGSize(width: 16, height: 10),
            proposedContentSize: CGSize(width: 1000, height: 700),
            layoutInsetSize: CGSize(width: 20, height: 10),
            scaleFactor: 2
        )

        #expect(approximatelyEqual(size?.width, 1000, tolerance: 0.01))
        #expect(approximatelyEqual(size?.height, 622.5, tolerance: 0.01))
    }

    @Test func aspectLockedContentSizeReturnsNilWhenAspectInvalid() {
        #expect(
            CapturePreviewGeometry.aspectLockedContentSize(
                aspect: .zero,
                proposedContentSize: CGSize(width: 1000, height: 700),
                layoutInsetSize: CGSize(width: 20, height: 10),
                scaleFactor: 2
            ) == nil
        )
    }
}

private func approximatelyEqual(
    _ lhs: CGFloat?,
    _ rhs: CGFloat,
    tolerance: CGFloat
) -> Bool {
    guard let lhs else { return false }
    return abs(lhs - rhs) <= tolerance
}
