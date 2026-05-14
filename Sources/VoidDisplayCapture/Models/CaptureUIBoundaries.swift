import CoreGraphics
import Foundation
import ScreenCaptureKit
import VoidDisplayFoundation

@MainActor
package struct CaptureMonitoringActions {
    package var sessions: @MainActor () -> [ScreenMonitoringSession]
    package var monitoringSession: @MainActor (UUID) -> ScreenMonitoringSession?
    package var monitoringSessionForDisplayID: @MainActor (CGDirectDisplayID) -> ScreenMonitoringSession?
    package var isStartingDisplayID: @MainActor (CGDirectDisplayID) -> Bool
    package var startMonitoring: @MainActor (
        SCDisplay,
        CaptureMonitoringDisplayMetadata
    ) async throws -> DisplayStartOutcome<UUID>
    package var attachPreviewSink: @MainActor (any DisplayPreviewSink, UUID) -> Void
    package var activateMonitoringSession: @MainActor (UUID) -> Void
    package var attachDiagnosticsRecorder: @MainActor (UUID) async -> UUID?
    package var detachDiagnosticsRecorder: @MainActor (UUID) async -> Void
    package var closeMonitoringSession: @MainActor (UUID) -> Void
    package var setMonitoringSessionCapturesCursor: @MainActor (UUID, Bool) async throws -> Void

    package init(
        sessions: @escaping @MainActor () -> [ScreenMonitoringSession],
        monitoringSession: @escaping @MainActor (UUID) -> ScreenMonitoringSession?,
        monitoringSessionForDisplayID: @escaping @MainActor (CGDirectDisplayID) -> ScreenMonitoringSession?,
        isStartingDisplayID: @escaping @MainActor (CGDirectDisplayID) -> Bool,
        startMonitoring: @escaping @MainActor (
            SCDisplay,
            CaptureMonitoringDisplayMetadata
        ) async throws -> DisplayStartOutcome<UUID>,
        attachPreviewSink: @escaping @MainActor (any DisplayPreviewSink, UUID) -> Void,
        activateMonitoringSession: @escaping @MainActor (UUID) -> Void,
        attachDiagnosticsRecorder: @escaping @MainActor (UUID) async -> UUID? = { _ in UUID() },
        detachDiagnosticsRecorder: @escaping @MainActor (UUID) async -> Void = { _ in },
        closeMonitoringSession: @escaping @MainActor (UUID) -> Void,
        setMonitoringSessionCapturesCursor: @escaping @MainActor (UUID, Bool) async throws -> Void
    ) {
        self.sessions = sessions
        self.monitoringSession = monitoringSession
        self.monitoringSessionForDisplayID = monitoringSessionForDisplayID
        self.isStartingDisplayID = isStartingDisplayID
        self.startMonitoring = startMonitoring
        self.attachPreviewSink = attachPreviewSink
        self.activateMonitoringSession = activateMonitoringSession
        self.attachDiagnosticsRecorder = attachDiagnosticsRecorder
        self.detachDiagnosticsRecorder = detachDiagnosticsRecorder
        self.closeMonitoringSession = closeMonitoringSession
        self.setMonitoringSessionCapturesCursor = setMonitoringSessionCapturesCursor
    }

    package static let noop = CaptureMonitoringActions(
        sessions: { [] },
        monitoringSession: { _ in nil },
        monitoringSessionForDisplayID: { _ in nil },
        isStartingDisplayID: { _ in false },
        startMonitoring: { _, _ in .invalidated },
        attachPreviewSink: { _, _ in },
        activateMonitoringSession: { _ in },
        closeMonitoringSession: { _ in },
        setMonitoringSessionCapturesCursor: { _, _ in }
    )
}

@MainActor
package struct CaptureSharingStatusProvider {
    package var isDisplaySharing: @MainActor (CGDirectDisplayID) -> Bool

    package init(isDisplaySharing: @escaping @MainActor (CGDirectDisplayID) -> Bool) {
        self.isDisplaySharing = isDisplaySharing
    }

    package static let none = CaptureSharingStatusProvider { _ in false }
}

@MainActor
package struct CaptureVirtualDisplayStatusProvider {
    package var isManagedVirtualDisplay: @MainActor (CGDirectDisplayID) -> Bool

    package init(isManagedVirtualDisplay: @escaping @MainActor (CGDirectDisplayID) -> Bool) {
        self.isManagedVirtualDisplay = isManagedVirtualDisplay
    }

    package static let none = CaptureVirtualDisplayStatusProvider { _ in false }
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

    package static let noop = CaptureCatalogActions(
        handleAppear: {},
        handleDisappear: {},
        handleTopologyChanged: {},
        requestPermission: {},
        refreshPermission: {},
        forceRefresh: {},
        openScreenCapturePrivacySettings: { _ in }
    )
}
