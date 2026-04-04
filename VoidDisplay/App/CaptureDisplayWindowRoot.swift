//
//  CaptureDisplayWindowRoot.swift
//  VoidDisplay
//

import SwiftUI

struct CaptureDisplayWindowRoot: View {
    @Environment(\.dismiss) private var dismiss
    let sessionId: UUID?
    @State private var hasSeenSessionID = false

    var body: some View {
        Group {
            if let sessionId {
                CaptureDisplayView(sessionId: sessionId)
                    .navigationTitle("Screen Monitoring")
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
