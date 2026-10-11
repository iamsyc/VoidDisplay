@testable import VoidDisplayCapture
import AppKit
import SwiftUI
import Testing

@MainActor
@Suite(.serialized)
struct CapturePreviewWindowLifetimeTests {
    @Test func closedPreviewDoesNotRetainItsHostingWindow() async throws {
        let previewID = CapturePreviewID(rawValue: UUID())
        let actions = CapturePreviewActions(
            sessions: { [] },
            previewSession: { _ in nil },
            previewState: { _ in .restarting },
            previewIDForDisplayID: { _ in nil },
            startPreview: { _, _ in throw CancellationError() },
            attachPreviewSink: { _, _ in },
            activatePreviewSession: { _ in },
            waitForPreviewResolution: { _ in .restarting },
            retryPreview: { _ in .restarting },
            closePreview: { _ in },
            setPreviewCapturesCursor: { _, _ in }
        )
        var window: NSWindow? = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window?.isReleasedWhenClosed = false
        window?.contentView = NSHostingView(rootView: CaptureDisplayView(
            previewID: previewID,
            previewActions: actions,
            sharingStatusProvider: .init(isDisplaySharing: { _ in false })
        ))
        window?.orderFront(nil)
        let attached = try await waitUntil {
            window?.delegate is CapturePreviewWindowCoordinator
        }
        #expect(attached, "The preview must resolve its real hosting window before checking ownership")

        weak let releasedWindow = window
        weak let releasedCoordinator = window?.delegate as? CapturePreviewWindowCoordinator
        #expect(releasedCoordinator != nil)
        window?.close()
        window = nil

        let released = try await waitUntil { releasedWindow == nil && releasedCoordinator == nil }
        #expect(released, "Closing a preview must release its window and view-owned coordinator")
    }

    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
