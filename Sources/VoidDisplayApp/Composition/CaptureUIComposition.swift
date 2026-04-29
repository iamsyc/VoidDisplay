import VoidDisplayCapture
import VoidDisplayVirtualDisplay

@MainActor
package enum CaptureUIComposition {
    package static func monitoringActions(capture: CaptureController) -> CaptureMonitoringActions {
        CaptureMonitoringActions(
            sessions: {
                capture.screenCaptureSessions
            },
            monitoringSession: { sessionID in
                capture.monitoringSession(for: sessionID)
            },
            monitoringSessionForDisplayID: { displayID in
                capture.screenCaptureSessions.first(where: { $0.displayID == displayID })
            },
            isStartingDisplayID: { displayID in
                capture.isStarting(displayID: displayID)
            },
            startMonitoring: { display, metadata in
                try await capture.startMonitoring(display: display, metadata: metadata)
            },
            attachPreviewSink: { sink, sessionID in
                capture.attachPreviewSink(sink, to: sessionID)
            },
            activateMonitoringSession: { sessionID in
                capture.activateMonitoringSession(id: sessionID)
            },
            closeMonitoringSession: { sessionID in
                capture.closeMonitoringSession(id: sessionID)
            },
            setMonitoringSessionCapturesCursor: { sessionID, capturesCursor in
                try await capture.setMonitoringSessionCapturesCursor(
                    id: sessionID,
                    capturesCursor: capturesCursor
                )
            }
        )
    }

    package static func sharingStatusProvider(sharing: SharingController) -> CaptureSharingStatusProvider {
        CaptureSharingStatusProvider { displayID in
            sharing.isDisplaySharing(displayID: displayID)
        }
    }

    package static func virtualDisplayStatusProvider(
        virtualDisplay: VirtualDisplayController
    ) -> CaptureVirtualDisplayStatusProvider {
        CaptureVirtualDisplayStatusProvider { displayID in
            virtualDisplay.isManagedVirtualDisplay(displayID: displayID)
        }
    }

    package static func catalogActions(screenCatalog: ScreenCatalogOrchestrator) -> CaptureCatalogActions {
        CaptureCatalogActions(
            handleAppear: {
                await screenCatalog.handleAppear(source: .capturePage)
            },
            handleDisappear: {
                await screenCatalog.handleDisappear(source: .capturePage)
            },
            handleTopologyChanged: {
                await screenCatalog.handleTopologyChanged()
            },
            requestPermission: {
                await screenCatalog.requestPermission(source: .capturePage)
            },
            refreshPermission: {
                await screenCatalog.refreshPermission(source: .capturePage)
            },
            forceRefresh: {
                await screenCatalog.forceRefresh(source: .capturePage)
            },
            openScreenCapturePrivacySettings: { openURL in
                screenCatalog.openScreenCapturePrivacySettings(openURL: openURL)
            }
        )
    }
}
