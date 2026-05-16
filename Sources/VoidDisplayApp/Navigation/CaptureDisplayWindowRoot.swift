import VoidDisplayCapture
import Foundation
//
//  CaptureDisplayWindowRoot.swift
//  VoidDisplay
//

import SwiftUI
package struct CaptureDisplayWindowRoot: View {
    @Environment(\.dismiss) private var dismiss
    package let sessionId: UUID?
    private let previewActions: CapturePreviewActions
    private let sharingStatusProvider: CaptureSharingStatusProvider
    @State private var hasSeenSessionID = false

    package init(
        sessionId: UUID?,
        previewActions: CapturePreviewActions,
        sharingStatusProvider: CaptureSharingStatusProvider
    ) {
        self.sessionId = sessionId
        self.previewActions = previewActions
        self.sharingStatusProvider = sharingStatusProvider
    }

    package var body: some View {
        Group {
            if let sessionId {
                CaptureDisplayView(
                    sessionId: sessionId,
                    previewActions: previewActions,
                    sharingStatusProvider: sharingStatusProvider
                )
                    .navigationTitle("Preview")
            } else {
                Color.clear
            }
        }
        .task(id: sessionId) {
            if sessionId != nil {
                hasSeenSessionID = true
                return
            }

            // Value-based windows can briefly render before their payload is
            // attached. Give SwiftUI one turn to supply the session ID.
            if !hasSeenSessionID {
                try? await Task.sleep(for: .milliseconds(150))
                guard sessionId == nil, !hasSeenSessionID else { return }
                dismiss()
                return
            }

            dismiss()
        }
    }
}
