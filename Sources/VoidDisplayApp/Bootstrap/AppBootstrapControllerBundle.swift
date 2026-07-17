import VoidDisplayCapture
import VoidDisplaySharing
import VoidDisplayVirtualDisplay

@MainActor
struct AppBootstrapControllerBundle {
    let capture: CaptureController
    let sharing: SharingController
    let virtualDisplay: VirtualDisplayController
}

extension AppBootstrap {
    static func makeControllerBundle(
        captureSharing: AppBootstrapCaptureSharingBundle,
        virtualDisplay: AppBootstrapVirtualDisplayBundle,
        persistence: AppBootstrapPersistenceBundle,
        appliedBadgeDisplayDuration: Duration
    ) -> AppBootstrapControllerBundle {
        let capture = CaptureController(
            capturePreviewService: captureSharing.capturePreviewService,
            capturePreviewLifecycleService: CapturePreviewLifecycleService(
                capturePreviewService: captureSharing.capturePreviewService,
                captureRegistry: captureSharing.captureRegistry
            ),
            catalogService: captureSharing.catalogService,
            observability: persistence.observability
        )
        let sharing = SharingController(
            sharingService: captureSharing.sharingService,
            portPreferences: SharingPortPreferences(defaults: persistence.context.userDefaults),
            catalogService: captureSharing.catalogService,
            observability: persistence.observability
        )
        let virtualDisplayController = VirtualDisplayController(
            virtualDisplayFacade: virtualDisplay.facade,
            appliedBadgeDisplayDuration: appliedBadgeDisplayDuration,
            observability: persistence.observability
        )
        return AppBootstrapControllerBundle(
            capture: capture,
            sharing: sharing,
            virtualDisplay: virtualDisplayController
        )
    }
}
