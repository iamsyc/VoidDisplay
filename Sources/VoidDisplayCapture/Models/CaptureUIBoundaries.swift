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
    package var isStartingDisplayID: @MainActor (CGDirectDisplayID) -> Bool
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
        isStartingDisplayID: @escaping @MainActor (CGDirectDisplayID) -> Bool,
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
        self.isStartingDisplayID = isStartingDisplayID
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

@MainActor
package struct CaptureVirtualDisplayStatusProvider {
    package var isManagedVirtualDisplay: @MainActor (CGDirectDisplayID) -> Bool

    package init(isManagedVirtualDisplay: @escaping @MainActor (CGDirectDisplayID) -> Bool) {
        self.isManagedVirtualDisplay = isManagedVirtualDisplay
    }
}

@MainActor
package struct CaptureCatalogActions {
    package var handleAppear: @MainActor () async -> Void
    package var handleDisappear: @MainActor () async -> Void
    package var handleTopologyChanged: @MainActor () async -> Void
    package var requestPermission: @MainActor () async -> Void
    package var refreshPermission: @MainActor () async -> Void
    package var forceRefresh: @MainActor () async -> Void
    package var openScreenCapturePrivacySettings: @MainActor (@escaping (URL) -> Void) -> Void

    package init(
        handleAppear: @escaping @MainActor () async -> Void,
        handleDisappear: @escaping @MainActor () async -> Void,
        handleTopologyChanged: @escaping @MainActor () async -> Void,
        requestPermission: @escaping @MainActor () async -> Void,
        refreshPermission: @escaping @MainActor () async -> Void,
        forceRefresh: @escaping @MainActor () async -> Void,
        openScreenCapturePrivacySettings: @escaping @MainActor (@escaping (URL) -> Void) -> Void
    ) {
        self.handleAppear = handleAppear
        self.handleDisappear = handleDisappear
        self.handleTopologyChanged = handleTopologyChanged
        self.requestPermission = requestPermission
        self.refreshPermission = refreshPermission
        self.forceRefresh = forceRefresh
        self.openScreenCapturePrivacySettings = openScreenCapturePrivacySettings
    }
}
