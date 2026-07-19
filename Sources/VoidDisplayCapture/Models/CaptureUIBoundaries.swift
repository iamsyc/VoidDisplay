import CoreGraphics
import Foundation
import ScreenCaptureKit
import VoidDisplayFoundation

@MainActor
package struct CapturePreviewActions {
    package var sessions: @MainActor () -> [ScreenPreviewSession]
    package var previewSession: @MainActor (CapturePreviewID) -> ScreenPreviewSession?
    package var previewState: @MainActor (CapturePreviewID) -> CapturePreviewState
    package var previewIDForDisplayID: @MainActor (CGDirectDisplayID) -> CapturePreviewID?
    package var startPreview: @MainActor (
        SCDisplay,
        CapturePreviewDisplayMetadata
    ) async throws -> DisplayStartOutcome<CapturePreviewID>
    package var attachPreviewSink: @MainActor (any DisplayPreviewSink, CapturePreviewID) -> Void
    package var activatePreviewSession: @MainActor (CapturePreviewID) -> Void
    package var waitForPreviewResolution: @MainActor (CapturePreviewID) async -> CapturePreviewState
    package var retryPreview: @MainActor (CapturePreviewID) async -> CapturePreviewState
    package var closePreview: @MainActor (CapturePreviewID) async -> Void
    package var setPreviewCapturesCursor: @MainActor (CapturePreviewID, Bool) async throws -> Void

    package init(
        sessions: @escaping @MainActor () -> [ScreenPreviewSession],
        previewSession: @escaping @MainActor (CapturePreviewID) -> ScreenPreviewSession?,
        previewState: @escaping @MainActor (CapturePreviewID) -> CapturePreviewState,
        previewIDForDisplayID: @escaping @MainActor (CGDirectDisplayID) -> CapturePreviewID?,
        startPreview: @escaping @MainActor (
            SCDisplay,
            CapturePreviewDisplayMetadata
        ) async throws -> DisplayStartOutcome<CapturePreviewID>,
        attachPreviewSink: @escaping @MainActor (any DisplayPreviewSink, CapturePreviewID) -> Void,
        activatePreviewSession: @escaping @MainActor (CapturePreviewID) -> Void,
        waitForPreviewResolution: @escaping @MainActor (CapturePreviewID) async -> CapturePreviewState,
        retryPreview: @escaping @MainActor (CapturePreviewID) async -> CapturePreviewState,
        closePreview: @escaping @MainActor (CapturePreviewID) async -> Void,
        setPreviewCapturesCursor: @escaping @MainActor (CapturePreviewID, Bool) async throws -> Void
    ) {
        self.sessions = sessions
        self.previewSession = previewSession
        self.previewState = previewState
        self.previewIDForDisplayID = previewIDForDisplayID
        self.startPreview = startPreview
        self.attachPreviewSink = attachPreviewSink
        self.activatePreviewSession = activatePreviewSession
        self.waitForPreviewResolution = waitForPreviewResolution
        self.retryPreview = retryPreview
        self.closePreview = closePreview
        self.setPreviewCapturesCursor = setPreviewCapturesCursor
    }
}

@MainActor
package struct CaptureSharingStatusProvider {
    package var isDisplaySharing: @MainActor (CGDirectDisplayID) -> Bool

    package init(isDisplaySharing: @escaping @MainActor (CGDirectDisplayID) -> Bool) {
        self.isDisplaySharing = isDisplaySharing
    }
}
