//
//  CaptureDisplayWindowRoot.swift
//  VoidDisplay
//

import AppKit
import Foundation
import SwiftUI
import VoidDisplayCapture

package struct CaptureDisplayWindowRoot: View {
    package let previewID: CapturePreviewID?
    private let previewActions: CapturePreviewActions
    private let sharingStatusProvider: CaptureSharingStatusProvider
    @State private var waitingWindow: NSWindow?

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
        case .waitingForPreviewID:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(Text(waitingWindow?.title ?? ""))
                .accessibilityIdentifier("capture_preview_waiting_for_identity")
                .navigationTitle(String(localized: "Preview"))
                .overlay {
                    CapturePreviewWindowAccessor { window in
                        guard waitingWindow !== window else { return }
                        waitingWindow = window
                    }
                    .allowsHitTesting(false)
                }
        }
    }
}
