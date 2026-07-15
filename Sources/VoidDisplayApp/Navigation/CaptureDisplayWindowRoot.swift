import VoidDisplayCapture
import Foundation
//
//  CaptureDisplayWindowRoot.swift
//  VoidDisplay
//

import SwiftUI
package struct CaptureDisplayWindowRoot: View {
    @Environment(\.dismiss) private var dismiss
    package let previewID: CapturePreviewID?
    private let previewActions: CapturePreviewActions
    private let sharingStatusProvider: CaptureSharingStatusProvider
    @State private var hasSeenPreviewID = false

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
        Group {
            if let previewID {
                CaptureDisplayView(
                    previewID: previewID,
                    previewActions: previewActions,
                    sharingStatusProvider: sharingStatusProvider
                )
                    .navigationTitle("Preview")
            } else {
                Color.clear
            }
        }
        .task(id: previewID) {
            if previewID != nil {
                hasSeenPreviewID = true
                return
            }

            // Value-based windows can briefly render before their payload is
            // attached. Give SwiftUI one turn to supply the stable preview ID.
            if !hasSeenPreviewID {
                try? await Task.sleep(for: .milliseconds(150))
                guard previewID == nil, !hasSeenPreviewID else { return }
                dismiss()
                return
            }

            dismiss()
        }
    }
}
