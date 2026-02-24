//
//  CaptureDisplayWindowRoot.swift
//  VoidDisplay
//

import SwiftUI

struct CaptureDisplayWindowRoot: View {
    @Environment(\.dismiss) private var dismiss
    let sessionId: UUID?

    var body: some View {
        if let sessionId {
            CaptureDisplayView(sessionId: sessionId)
                .navigationTitle("Screen Monitoring")
        } else {
            Color.clear
                .onAppear { dismiss() }
        }
    }
}
