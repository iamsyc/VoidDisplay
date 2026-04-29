import CoreGraphics
import Foundation
package struct CapturePreviewGeometry {
    package struct InitialContentSizeInput {
        let aspect: CGSize
        let framePixelSize: CGSize
        let targetContentWidth: CGFloat?
        let visibleFrameSize: CGSize
        let chromeSize: CGSize
        let layoutInsetSize: CGSize
        let scaleFactor: CGFloat
    }

    nonisolated static func parseResolution(_ text: String?) -> CGSize? {
        guard let text else { return nil }
        let separators: [Character] = ["×", "x", "X", "*"]
        guard let separator = separators.first(where: { text.contains($0) }) else { return nil }
        let parts = text.split(separator: separator, maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2,
              let width = Double(parts[0]), width > 0,
              let height = Double(parts[1]), height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    nonisolated static func preferredAspect(
        resolutionText: String?,
        framePixelSize: CGSize
    ) -> CGSize {
        parseResolution(resolutionText) ?? framePixelSize
    }

    nonisolated static func nativeFrameSizeInPoints(
        framePixelSize: CGSize,
        scaleFactor: CGFloat,
        fallbackAspect: CGSize
    ) -> CGSize {
        guard framePixelSize.width > 0, framePixelSize.height > 0 else {
            return CGSize(width: max(1, fallbackAspect.width), height: max(1, fallbackAspect.height))
        }
        let sanitizedScale = max(1, scaleFactor)
        return CGSize(
            width: max(1, framePixelSize.width / sanitizedScale),
            height: max(1, framePixelSize.height / sanitizedScale)
        )
    }

    nonisolated static func initialContentSize(input: InitialContentSizeInput) -> CGSize? {
        guard input.aspect.width > 0, input.aspect.height > 0 else { return nil }

        let maxPreviewWidth = max(
            320,
            input.visibleFrameSize.width - input.chromeSize.width - input.layoutInsetSize.width - 16
        )
        let maxPreviewHeight = max(
            180,
            input.visibleFrameSize.height - input.chromeSize.height - input.layoutInsetSize.height - 16
        )

        let ratio = input.aspect.width / input.aspect.height
        let scale = max(1, input.scaleFactor)
        let pixelSize = input.framePixelSize
        let defaultPreviewWidth = max(320, maxPreviewWidth * 0.70)
        let defaultPreviewHeight = defaultPreviewWidth / ratio
        var previewWidth = defaultPreviewWidth
        var previewHeight = defaultPreviewHeight

        if pixelSize.width > 0, pixelSize.height > 0 {
            previewWidth = pixelSize.width / scale
            previewHeight = pixelSize.height / scale
        }

        if let overriddenWidth = input.targetContentWidth {
            previewWidth = min(max(320, overriddenWidth), maxPreviewWidth)
            previewHeight = previewWidth / ratio
        }

        if previewWidth > maxPreviewWidth {
            previewWidth = maxPreviewWidth
            previewHeight = previewWidth / ratio
        }
        if previewHeight > maxPreviewHeight {
            previewHeight = maxPreviewHeight
            previewWidth = previewHeight * ratio
        }

        return CGSize(
            width: previewWidth + input.layoutInsetSize.width,
            height: previewHeight + input.layoutInsetSize.height
        )
    }

    nonisolated static func aspectLockedContentSize(
        aspect: CGSize,
        proposedContentSize: CGSize,
        layoutInsetSize: CGSize,
        scaleFactor: CGFloat
    ) -> CGSize? {
        guard aspect.width > 0, aspect.height > 0 else { return nil }
        let scale = max(1, scaleFactor)

        let insetWidthPixels = max(0, Int((layoutInsetSize.width * scale).rounded()))
        let insetHeightPixels = max(0, Int((layoutInsetSize.height * scale).rounded()))
        let proposedPreviewWidthPixels = max(
            1,
            Int(((proposedContentSize.width - layoutInsetSize.width) * scale).rounded(.down))
        )
        let proposedPreviewHeightPixels = max(
            1,
            Int(((proposedContentSize.height - layoutInsetSize.height) * scale).rounded(.down))
        )
        let aspectWidthPixels = max(1, Int(aspect.width.rounded()))
        let aspectHeightPixels = max(1, Int(aspect.height.rounded()))

        let previewWidthPixels: Int
        let previewHeightPixels: Int

        if proposedPreviewWidthPixels * aspectHeightPixels > proposedPreviewHeightPixels * aspectWidthPixels {
            previewHeightPixels = proposedPreviewHeightPixels
            previewWidthPixels = max(
                1,
                Int((CGFloat(previewHeightPixels) * aspect.width / aspect.height).rounded(.down))
            )
        } else {
            previewWidthPixels = proposedPreviewWidthPixels
            previewHeightPixels = max(
                1,
                Int((CGFloat(previewWidthPixels) * aspect.height / aspect.width).rounded(.down))
            )
        }

        return CGSize(
            width: CGFloat(previewWidthPixels + insetWidthPixels) / scale,
            height: CGFloat(previewHeightPixels + insetHeightPixels) / scale
        )
    }
}
