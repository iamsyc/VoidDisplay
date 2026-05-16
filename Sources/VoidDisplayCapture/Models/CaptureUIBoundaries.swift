import CoreGraphics
import Foundation
import ScreenCaptureKit
import VoidDisplayFoundation

@MainActor
package struct CapturePreviewActions {
    package var sessions: @MainActor () -> [ScreenPreviewSession]
    package var previewSession: @MainActor (UUID) -> ScreenPreviewSession?
    package var previewSessionForDisplayID: @MainActor (CGDirectDisplayID) -> ScreenPreviewSession?
    package var isStartingDisplayID: @MainActor (CGDirectDisplayID) -> Bool
    package var startPreview: @MainActor (
        SCDisplay,
        CapturePreviewDisplayMetadata
    ) async throws -> DisplayStartOutcome<UUID>
    package var attachPreviewSink: @MainActor (any DisplayPreviewSink, UUID) -> Void
    package var activatePreviewSession: @MainActor (UUID) -> Void
    package var closePreviewSession: @MainActor (UUID) async -> Void
    package var setPreviewSessionCapturesCursor: @MainActor (UUID, Bool) async throws -> Void

    package init(
        sessions: @escaping @MainActor () -> [ScreenPreviewSession],
        previewSession: @escaping @MainActor (UUID) -> ScreenPreviewSession?,
        previewSessionForDisplayID: @escaping @MainActor (CGDirectDisplayID) -> ScreenPreviewSession?,
        isStartingDisplayID: @escaping @MainActor (CGDirectDisplayID) -> Bool,
        startPreview: @escaping @MainActor (
            SCDisplay,
            CapturePreviewDisplayMetadata
        ) async throws -> DisplayStartOutcome<UUID>,
        attachPreviewSink: @escaping @MainActor (any DisplayPreviewSink, UUID) -> Void,
        activatePreviewSession: @escaping @MainActor (UUID) -> Void,
        closePreviewSession: @escaping @MainActor (UUID) async -> Void,
        setPreviewSessionCapturesCursor: @escaping @MainActor (UUID, Bool) async throws -> Void
    ) {
        self.sessions = sessions
        self.previewSession = previewSession
        self.previewSessionForDisplayID = previewSessionForDisplayID
        self.isStartingDisplayID = isStartingDisplayID
        self.startPreview = startPreview
        self.attachPreviewSink = attachPreviewSink
        self.activatePreviewSession = activatePreviewSession
        self.closePreviewSession = closePreviewSession
        self.setPreviewSessionCapturesCursor = setPreviewSessionCapturesCursor
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
