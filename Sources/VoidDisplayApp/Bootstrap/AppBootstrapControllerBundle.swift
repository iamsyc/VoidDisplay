import VoidDisplayCapture
import VoidDisplaySharing
import VoidDisplayVirtualDisplay

@MainActor
struct AppBootstrapBaseControllerBundle {
    let capture: CaptureController
    let sharing: SharingController
}

@MainActor
struct AppBootstrapControllerBundle {
    let capture: CaptureController
    let sharing: SharingController
    let virtualDisplay: VirtualDisplayController
}

extension AppBootstrap {
    static func makeBaseControllerBundle(
        captureSharing: AppBootstrapCaptureSharingBundle,
        persistence: AppBootstrapPersistenceBundle
    ) -> AppBootstrapBaseControllerBundle {
        let capture = CaptureController(
            capturePreviewService: captureSharing.capturePreviewService,
            capturePreviewLifecycleService: CapturePreviewLifecycleService(
                capturePreviewService: captureSharing.capturePreviewService,
                captureRegistry: captureSharing.captureRegistry,
                acquirePreview: PreviewUITestFixture.acquirePreview()
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
        return AppBootstrapBaseControllerBundle(capture: capture, sharing: sharing)
    }

    static func makeControllerBundle(
        base: AppBootstrapBaseControllerBundle,
        virtualDisplay: AppBootstrapVirtualDisplayBundle,
        persistence: AppBootstrapPersistenceBundle,
        runtime: AppBootstrapRuntimeBundle,
        appliedBadgeDisplayDuration: Duration
    ) -> AppBootstrapControllerBundle {
        let virtualDisplayController = VirtualDisplayController(
            virtualDisplayFacade: virtualDisplay.facade,
            runtimeExecutors: makeVirtualDisplayRuntimeExecutors(runtime: runtime.displayRuntime),
            appliedBadgeDisplayDuration: appliedBadgeDisplayDuration,
            observability: persistence.observability
        )
        return AppBootstrapControllerBundle(
            capture: base.capture,
            sharing: base.sharing,
            virtualDisplay: virtualDisplayController
        )
    }
}
