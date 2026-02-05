//
//  CaptureDisplayView.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/5.
//

import SwiftUI
import ScreenCaptureKit
import CoreImage

struct CaptureDisplayView: View {
    let sessionId: UUID

    @EnvironmentObject var appHelper: AppHelper
    @Environment(\.dismiss) private var dismiss

    @StateObject private var captureOut = Capture()
    @State private var cgImage: CGImage?
    @State private var startTask: Task<Void, Never>?

    private var session: AppHelper.ScreenMonitoringSession? {
        appHelper.monitoringSession(for: sessionId)
    }

    var body: some View {
        Group {
            if let image = cgImage {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .scaledToFit()
            } else {
                Text("No Data")
            }
        }
        .onReceive(appHelper.$screenCaptureSessions) { sessions in
            if !sessions.contains(where: { $0.id == sessionId }) {
                startTask?.cancel()
                startTask = nil
                dismiss()
            }
        }
        .onChange(of: captureOut.surface) {
            guard let surface = captureOut.surface else { return }
            let ciImage = CIImage(cvPixelBuffer: surface)
            let context = CIContext()
            cgImage = context.createCGImage(ciImage, from: ciImage.extent)
        }
        .onAppear {
            guard let session else {
                dismiss()
                return
            }

            try? session.stream.addStreamOutput(captureOut, type: .screen, sampleHandlerQueue: .main)
            startTask?.cancel()
            startTask = Task {
                try? await session.stream.startCapture()
            }
        }
        .onDisappear {
            startTask?.cancel()
            startTask = nil
            appHelper.removeMonitoringSession(id: sessionId)
        }
        .background(.black)
    }
}

