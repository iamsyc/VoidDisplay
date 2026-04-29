import AppKit
@MainActor
package final class CapturePreviewWindowCoordinator: NSObject {
    private weak var window: NSWindow?
    nonisolated(unsafe) private var forwardedDelegate: (any NSWindowDelegate)?
    private var aspect = CGSize.zero
    private var shouldLockAspect = true

    package func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        restoreWindowDelegate()
        self.window = window
        if let delegate = window.delegate, delegate !== self {
            forwardedDelegate = delegate
        } else {
            forwardedDelegate = nil
        }
        window.delegate = self
    }

    package func update(aspect: CGSize, shouldLockAspect: Bool) {
        self.aspect = aspect
        self.shouldLockAspect = shouldLockAspect
    }

    package func snapWindowToAspect(_ window: NSWindow) {
        guard shouldLockAspect, aspect.width > 0, aspect.height > 0 else { return }
        let targetSize = aspectLockedFrameSize(for: window, proposedFrameSize: window.frame.size)
        guard abs(targetSize.width - window.frame.width) > 0.5
                || abs(targetSize.height - window.frame.height) > 0.5 else { return }

        var newFrame = window.frame
        newFrame.origin.x += (newFrame.width - targetSize.width) / 2
        newFrame.origin.y += (newFrame.height - targetSize.height) / 2
        newFrame.size = targetSize
        window.setFrame(newFrame, display: true, animate: false)
    }

    package func tearDown() {
        restoreWindowDelegate()
        window = nil
        forwardedDelegate = nil
    }

    private func aspectLockedFrameSize(for window: NSWindow, proposedFrameSize: NSSize) -> NSSize {
        guard let targetContentSize = aspectLockedContentSize(
            for: window,
            proposedFrameSize: proposedFrameSize
        ) else {
            return proposedFrameSize
        }

        let targetContentRect = NSRect(origin: .zero, size: targetContentSize)
        return window.frameRect(forContentRect: targetContentRect).size
    }

    private func aspectLockedContentSize(for window: NSWindow, proposedFrameSize: NSSize) -> NSSize? {
        let currentContentRect = window.contentRect(forFrameRect: window.frame)
        let currentLayoutRect = window.contentLayoutRect
        let proposedContentRect = window.contentRect(
            forFrameRect: NSRect(origin: .zero, size: proposedFrameSize)
        )
        let targetContentSize = CapturePreviewGeometry.aspectLockedContentSize(
            aspect: aspect,
            proposedContentSize: proposedContentRect.size,
            layoutInsetSize: CGSize(
                width: max(0, currentContentRect.width - currentLayoutRect.width),
                height: max(0, currentContentRect.height - currentLayoutRect.height)
            ),
            scaleFactor: max(1, window.backingScaleFactor)
        )
        guard let targetContentSize else { return nil }
        return NSSize(width: targetContentSize.width, height: targetContentSize.height)
    }

    private func restoreWindowDelegate() {
        guard let window, window.delegate === self else { return }
        window.delegate = forwardedDelegate
    }
}

extension CapturePreviewWindowCoordinator: NSWindowDelegate {
    package nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (forwardedDelegate?.responds(to: aSelector) ?? false)
    }

    package nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if forwardedDelegate?.responds(to: aSelector) == true {
            return forwardedDelegate
        }
        return super.forwardingTarget(for: aSelector)
    }

    package func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposedFrameSize = forwardedDelegate?.windowWillResize?(sender, to: frameSize) ?? frameSize
        guard shouldLockAspect, aspect.width > 0, aspect.height > 0 else {
            return proposedFrameSize
        }
        return aspectLockedFrameSize(for: sender, proposedFrameSize: proposedFrameSize)
    }

    package func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let proposedFrame = forwardedDelegate?.windowWillUseStandardFrame?(window, defaultFrame: newFrame)
            ?? newFrame
        guard shouldLockAspect, aspect.width > 0, aspect.height > 0 else {
            return proposedFrame
        }

        let targetSize = aspectLockedFrameSize(for: window, proposedFrameSize: proposedFrame.size)
        var adjustedFrame = proposedFrame
        adjustedFrame.origin.x += (proposedFrame.width - targetSize.width) / 2
        adjustedFrame.origin.y += (proposedFrame.height - targetSize.height) / 2
        adjustedFrame.size = targetSize
        return adjustedFrame
    }

    package func window(
        _ window: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
    ) -> NSApplication.PresentationOptions {
        let forwardedOptions = forwardedDelegate?.window?(
            window,
            willUseFullScreenPresentationOptions: proposedOptions
        ) ?? proposedOptions
        return forwardedOptions.union(.autoHideToolbar)
    }
}
