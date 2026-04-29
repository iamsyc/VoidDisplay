import VoidDisplayCapture
import VoidDisplaySharing
import VoidDisplayVirtualDisplay

@MainActor
package enum SharingUIComposition {
    package static func runtimeState(sharing: SharingController) -> ShareRuntimeState {
        let catalogDisplayIDs = Set((sharing.displayCatalogState.displays ?? []).map(\.displayID))
        let displayIDs = catalogDisplayIDs
            .union(sharing.activeSharingDisplayIDs)
            .union(sharing.startingDisplayIDs)
        let sharePageAddresses = Dictionary(
            uniqueKeysWithValues: displayIDs.compactMap { displayID in
                sharing.sharePageAddress(for: displayID).map { (displayID, $0) }
            }
        )

        return ShareRuntimeState(
            isWebServiceRunning: sharing.isWebServiceRunning,
            activeSharingDisplayIDs: sharing.activeSharingDisplayIDs,
            startingDisplayIDs: sharing.startingDisplayIDs,
            sharingClientCount: sharing.sharingClientCount,
            sharingClientCounts: sharing.sharingClientCounts,
            sharePageAddresses: sharePageAddresses
        )
    }

    package static func dependencies(
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController
    ) -> ShareViewModel.Dependencies {
        ShareViewModel.Dependencies(
            sharingQueries: .init(
                isWebServiceRunning: { sharing.isWebServiceRunning },
                activeSharingDisplayCount: { sharing.activeSharingDisplayIDs.count },
                sharingClientCount: { sharing.sharingClientCount },
                isDisplaySharing: { displayID in sharing.isDisplaySharing(displayID: displayID) },
                isStartingDisplayID: { displayID in sharing.isStarting(displayID: displayID) },
                displayClientCount: { displayID in sharing.sharingClientCounts[displayID] ?? 0 },
                sharePageAddress: { displayID in sharing.sharePageAddress(for: displayID) },
                preferredWebServicePort: { sharing.preferredWebServicePort }
            ),
            sharingActions: .init(
                startWebService: { requestedPort in
                    await sharing.startWebService(requestedPort: requestedPort)
                },
                stopWebService: {
                    sharing.stopWebService()
                },
                registerShareableDisplays: { displays, resolver in
                    sharing.registerShareableDisplays(displays, virtualSerialResolver: resolver)
                },
                beginSharing: { display in
                    try await sharing.beginSharing(display: display)
                },
                stopSharing: { displayID in
                    sharing.stopSharing(displayID: displayID)
                }
            ),
            virtualDisplayQueries: .init(
                virtualSerialForManagedDisplay: { displayID in
                    virtualDisplay.virtualSerialForManagedDisplay(displayID)
                }
            )
        )
    }

    package static func catalogActions(
        screenCatalog: ScreenCatalogOrchestrator
    ) -> ShareCatalogActions {
        ShareCatalogActions(
            handleAppear: {
                await screenCatalog.handleAppear(source: .sharingPage)
            },
            handleDisappear: {
                await screenCatalog.handleDisappear(source: .sharingPage)
            },
            handleTopologyChanged: {
                await screenCatalog.handleTopologyChanged()
            },
            requestPermission: {
                await screenCatalog.requestPermission(source: .sharingPage)
            },
            refreshPermission: {
                await screenCatalog.refreshPermission(source: .sharingPage)
            },
            forceRefresh: {
                await screenCatalog.forceRefresh(source: .sharingPage)
            },
            handleSharingServiceStateChanged: { isRunning in
                await screenCatalog.handleSharingServiceStateChanged(isRunning: isRunning)
            },
            openScreenCapturePrivacySettings: { openURL in
                screenCatalog.openScreenCapturePrivacySettings(openURL: openURL)
            }
        )
    }

    package static func displayStatusProvider(
        capture: CaptureController,
        virtualDisplay: VirtualDisplayController
    ) -> ShareDisplayStatusProvider {
        ShareDisplayStatusProvider { displayID in
            ShareDisplayStatus(
                isMonitoring: capture.screenCaptureSessions.contains { $0.displayID == displayID },
                isManagedVirtualDisplay: virtualDisplay.isManagedVirtualDisplay(displayID: displayID)
            )
        }
    }

    package static func performanceModeBinding(
        capturePerformancePreferences: CapturePerformancePreferences
    ) -> SharePerformanceModeBinding {
        SharePerformanceModeBinding(
            get: {
                sharePerformanceMode(from: capturePerformancePreferences.mode)
            },
            set: { mode in
                capturePerformancePreferences.saveMode(capturePerformanceMode(from: mode))
            }
        )
    }

    private static func sharePerformanceMode(
        from mode: CapturePerformanceMode
    ) -> SharePerformanceMode {
        switch mode {
        case .automatic:
            .automatic
        case .smooth:
            .smooth
        case .powerEfficient:
            .powerEfficient
        }
    }

    private static func capturePerformanceMode(
        from mode: SharePerformanceMode
    ) -> CapturePerformanceMode {
        switch mode {
        case .automatic:
            .automatic
        case .smooth:
            .smooth
        case .powerEfficient:
            .powerEfficient
        }
    }
}
