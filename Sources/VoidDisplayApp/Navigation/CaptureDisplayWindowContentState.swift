import VoidDisplayCapture

package enum CaptureDisplayWindowContentState: Equatable, Sendable {
    case waitingForPreviewID
    case preview(CapturePreviewID)

    package init(previewID: CapturePreviewID?) {
        if let previewID {
            self = .preview(previewID)
        } else {
            self = .waitingForPreviewID
        }
    }
}
