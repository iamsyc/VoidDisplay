@testable import VoidDisplayApp
@testable import VoidDisplayCapture
import Foundation
import Testing

@Suite
struct CaptureDisplayWindowContentStateTests {
    @Test func missingPreviewIDWaitsForPayload() {
        let state = CaptureDisplayWindowContentState(previewID: nil)

        #expect(state == .waitingForPreviewID)
    }

    @Test func availablePreviewIDResolvesPreviewContent() {
        let previewID = CapturePreviewID(rawValue: UUID())

        #expect(CaptureDisplayWindowContentState(previewID: previewID) == .preview(previewID))
    }
}
