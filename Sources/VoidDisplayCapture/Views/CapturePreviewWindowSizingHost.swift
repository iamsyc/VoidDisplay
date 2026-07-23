import AppKit
import CoreGraphics
import SwiftUI

package struct CapturePreviewWindowSizingHost: View {
    @Binding var window: NSWindow?
    @Binding var hasAppliedInitialSize: Bool

    let coordinator: CapturePreviewWindowCoordinator
    let scaleMode: CapturePreviewScaleMode
    let framePixelSize: CGSize
    let aspect: CGSize
    let targetContentWidth: CGFloat?

    private var shouldLockAspect: Bool {
        scaleMode == .fit
    }

    package var body: some View {
        CapturePreviewWindowAccessor { resolvedWindow in
            configure(resolvedWindow)
        }
        .onAppear {
            updateCoordinator()
            if let window {
                applyInitialWindowSize(to: window)
            }
        }
        .onChange(of: scaleMode) { _, _ in
            updateCoordinator()
            if shouldLockAspect, let window {
                coordinator.snapWindowToAspect(window)
            }
        }
        .onChange(of: framePixelSize) { _, _ in
            updateCoordinator()
            if let window {
                applyInitialWindowSize(to: window)
            }
        }
    }

    private func configure(_ resolvedWindow: NSWindow) {
        guard window !== resolvedWindow else { return }
        window = resolvedWindow
        coordinator.attach(to: resolvedWindow)
        updateCoordinator()
        applyInitialWindowSize(to: resolvedWindow)
    }

    private func updateCoordinator() {
        coordinator.update(aspect: aspect, shouldLockAspect: shouldLockAspect)
    }

    private func applyInitialWindowSize(to window: NSWindow) {
        guard aspect.width > 0, aspect.height > 0, !hasAppliedInitialSize else { return }

        window.backgroundColor = .windowBackgroundColor
        let contentRect = window.contentRect(forFrameRect: window.frame)
        let layoutRect = window.contentLayoutRect
        let targetContentSize = CapturePreviewGeometry.initialContentSize(
            input: .init(
                aspect: aspect,
                framePixelSize: framePixelSize,
                targetContentWidth: targetContentWidth,
                visibleFrameSize: (window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)?.size
                    ?? CGSize(width: 1280, height: 800),
                chromeSize: CGSize(
                    width: max(0, window.frame.width - contentRect.width),
                    height: max(0, window.frame.height - contentRect.height)
                ),
                layoutInsetSize: CGSize(
                    width: max(0, contentRect.width - layoutRect.width),
                    height: max(0, contentRect.height - layoutRect.height)
                ),
                scaleFactor: max(1, window.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
            )
        )
        guard let targetContentSize else { return }

        let targetFrame = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: NSSize(
                width: targetContentSize.width,
                height: targetContentSize.height
            ))
        )
        var newFrame = window.frame
        newFrame.origin.x += (newFrame.width - targetFrame.width) / 2
        newFrame.origin.y += (newFrame.height - targetFrame.height) / 2
        newFrame.size = targetFrame.size
        window.setFrame(newFrame, display: true, animate: false)

        hasAppliedInitialSize = true
    }
}
