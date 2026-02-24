//
//  CaptureDisplayView.swift
//  VoidDisplay
//
//

import SwiftUI
import ScreenCaptureKit
import CoreImage
import AppKit

struct CaptureDisplayView: View {
    let sessionId: UUID

    @Environment(CaptureController.self) private var capture
    @Environment(\.dismiss) private var dismiss

    @State private var captureOut = Capture()
    @State private var cgImage: CGImage?
    @State private var ciContext = CIContext()
    @State private var startTask: Task<Void, Never>?
    @State private var window: NSWindow?
    @State private var framePixelSize: CGSize = .zero
    @State private var hasAppliedInitialSize = false

    private var session: ScreenMonitoringSession? {
        capture.monitoringSession(for: sessionId)
    }

    var body: some View {
        ZStack {
            Color.black

            if let image = cgImage {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .scaledToFill()
            } else {
                Text("No Data")
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .clipped()
        .onChange(of: capture.screenCaptureSessions.map(\.id)) { _, ids in
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

            startTask?.cancel()
            startTask = Task { @MainActor in
                do {
                    try session.stream.addStreamOutput(
                        captureOut,
                        type: .screen,
                        sampleHandlerQueue: captureOut.sampleHandlerQueue
                    )
                    try await session.stream.startCapture()
                    capture.markMonitoringSessionActive(id: sessionId)
                } catch is CancellationError {
                    return
                } catch {
                    AppErrorMapper.logFailure("Start monitoring stream", error: error, logger: AppLog.capture)
                    capture.removeMonitoringSession(id: sessionId)
                    dismiss()
                }
            }
        }
        .onDisappear {
            startTask?.cancel()
            startTask = nil
            capture.removeMonitoringSession(id: sessionId)
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

    }

    private func applyWindowAspectIfNeeded() {
        let preferredAspect = preferredAspectFromSessionResolution() ?? framePixelSize
        guard
            let window,
            preferredAspect.width > 0,
            preferredAspect.height > 0
        else { return }

        let aspect = preferredAspect
        let currentContentRect = window.contentRect(forFrameRect: window.frame)
        guard currentContentRect.width > 0, currentContentRect.height > 0 else { return }

        if hasAppliedInitialSize { return }

        let targetAspectRatio = aspect.width / aspect.height

        window.contentAspectRatio = NSSize(width: aspect.width, height: aspect.height)

        let frameChromeWidth = window.frame.width - currentContentRect.width
        let frameChromeHeight = window.frame.height - currentContentRect.height
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame

        let maxContentWidth = max(320, (visibleFrame?.width ?? currentContentRect.width) - frameChromeWidth - 16)
        let maxContentHeight = max(180, (visibleFrame?.height ?? currentContentRect.height) - frameChromeHeight - 16)

        // Start from a height-based sizing: 60% of screen height, then derive width from aspect ratio.
        // This avoids the "window starts too wide" problem when SwiftUI opens with a default size.
        let idealContentHeight = min(maxContentHeight, (visibleFrame?.height ?? 800) * 0.6)
        var targetContentWidth = idealContentHeight * targetAspectRatio
        var targetContentHeight = idealContentHeight

        if targetContentWidth > maxContentWidth {
            targetContentWidth = maxContentWidth
            targetContentHeight = targetContentWidth / targetAspectRatio
        }

        if targetContentHeight > maxContentHeight {
            targetContentHeight = maxContentHeight
            targetContentWidth = targetContentHeight * targetAspectRatio
        }

        let targetContentSize = NSSize(width: targetContentWidth, height: targetContentHeight)
        let targetFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContentSize))

        var newFrame = window.frame
        // Center the new frame on the old frame's center
        newFrame.origin.x += (newFrame.width - targetFrame.width) / 2
        newFrame.origin.y += (newFrame.height - targetFrame.height) / 2
        newFrame.size = targetFrame.size
        window.setFrame(newFrame, display: true, animate: false)

        hasAppliedInitialSize = true
    }

    private func preferredAspectFromSessionResolution() -> CGSize? {
        guard let text = session?.resolutionText else { return nil }

        let separators = ["×", "x", "X", "*"]
        guard let separator = separators.first(where: { text.contains($0) }) else { return nil }
        let parts = text.split(separator: Character(separator), maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count == 2 else { return nil }
        guard
            let width = Double(parts[0]),
            let height = Double(parts[1]),
            width > 0,
            height > 0
        else {
            return nil
        }
        return CGSize(width: width, height: height)
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
