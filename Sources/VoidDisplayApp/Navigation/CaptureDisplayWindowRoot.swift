import VoidDisplayCapture
import Foundation
//
//  CaptureDisplayWindowRoot.swift
//  VoidDisplay
//

import SwiftUI
package struct CaptureDisplayWindowRoot: View {
    package let previewID: CapturePreviewID?
    private let previewActions: CapturePreviewActions
    private let sharingStatusProvider: CaptureSharingStatusProvider

    package init(
        previewID: CapturePreviewID?,
        previewActions: CapturePreviewActions,
        sharingStatusProvider: CaptureSharingStatusProvider
    ) {
        self.previewID = previewID
        self.previewActions = previewActions
        self.sharingStatusProvider = sharingStatusProvider
    }

    package var body: some View {
        switch CaptureDisplayWindowContentState(previewID: previewID) {
        case let .preview(resolvedPreviewID):
            CaptureDisplayView(
                previewID: resolvedPreviewID,
                previewActions: previewActions,
                sharingStatusProvider: sharingStatusProvider
            )
                .navigationTitle("Preview")
        case .waitingForPreviewID:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(Text("Preview"))
                .accessibilityIdentifier("capture_preview_waiting_for_identity")
        }
    }
}
