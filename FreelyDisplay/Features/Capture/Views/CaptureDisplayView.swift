//
//  CaptureDisplayView.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/5.
//

import SwiftUI
import ScreenCaptureKit
import CoreImage
import AppKit

struct CaptureDisplayView: View {
    let sessionId: UUID

    @Environment(AppHelper.self) private var appHelper: AppHelper
    @Environment(\.dismiss) private var dismiss

    @State private var captureOut = Capture()
    @State private var cgImage: CGImage?
    @State private var ciContext = CIContext()
    @State private var startTask: Task<Void, Never>?
    @State private var window: NSWindow?
    @State private var framePixelSize: CGSize = .zero
    @State private var lastAppliedAspect: CGSize = .zero

    private var session: AppHelper.ScreenMonitoringSession? {
        appHelper.monitoringSession(for: sessionId)
    }

    var body: some View {
        ZStack {
            Color.black

            if let image = cgImage {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .scaledToFit()
            } else {
                Text("No Data")
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .onChange(of: appHelper.screenCaptureSessions.map(\.id)) { _, ids in
            if !ids.contains(sessionId) {
                startTask?.cancel()
                startTask = nil
                dismiss()
            }
        }
        .onChange(of: captureOut.frameNumber) { _, _ in
            guard let surface = captureOut.surface else { return }
            let ciImage = CIImage(cvPixelBuffer: surface)
            cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent)
            framePixelSize = ciImage.extent.size
            applyWindowAspectIfNeeded()
        }
        .onAppear {
            guard let session else {
                dismiss()
                return
            }

            try? session.stream.addStreamOutput(
                captureOut,
                type: .screen,
                sampleHandlerQueue: captureOut.sampleHandlerQueue
            )
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
        .overlay {
            WindowAccessor { currentWindow in
                if window !== currentWindow {
                    window = currentWindow
                    applyWindowAspectIfNeeded()
                }
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func applyWindowAspectIfNeeded() {
        guard
            let window,
            framePixelSize.width > 0,
            framePixelSize.height > 0
        else { return }

        let aspect = framePixelSize
        if lastAppliedAspect == aspect { return }

        window.contentAspectRatio = NSSize(width: aspect.width, height: aspect.height)

        let currentContentRect = window.contentRect(forFrameRect: window.frame)
        guard currentContentRect.height > 0 else {
            lastAppliedAspect = aspect
            return
        }

        let targetContentWidth = currentContentRect.height * aspect.width / aspect.height
        let targetContentSize = NSSize(width: targetContentWidth, height: currentContentRect.height)
        let targetFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContentSize))

        var newFrame = window.frame
        newFrame.origin.y += newFrame.height - targetFrame.height
        newFrame.size = targetFrame.size
        window.setFrame(newFrame, display: true, animate: false)
        lastAppliedAspect = aspect
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}
