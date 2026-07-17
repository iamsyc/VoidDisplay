import VoidDisplayCapture
import VoidDisplayFoundation
import VoidDisplaySharing

@MainActor
struct AppBootstrapCaptureSharingBundle {
    let capturePreviewService: any CapturePreviewServiceProtocol
    let catalogService: ScreenCaptureCatalogService
    let captureRegistry: DisplayCaptureRegistry
    let sharingService: any SharingServiceProtocol
}

extension AppBootstrap {
    static func makeCaptureSharingBundle(
        capturePreviewService: (any CapturePreviewServiceProtocol)?,
        sharingService: (any SharingServiceProtocol)?,
        persistence: AppBootstrapPersistenceBundle
    ) -> AppBootstrapCaptureSharingBundle {
        let resolvedCapturePreviewService = capturePreviewService ?? CapturePreviewService()
        let catalogService = ScreenCaptureCatalogService()
        let relayProcessController = RelayProcessController()
        let captureRegistry = DisplayCaptureRegistry(
            performanceMode: persistence.capturePerformancePreferences.mode,
            makeShareFrameConsumer: {
                RelaySessionHub(relayProcessController: relayProcessController)
            }
        )

        let resolvedSharingService = sharingService ?? makeSharingService(
            persistence: persistence,
            relayProcessController: relayProcessController,
            captureRegistry: captureRegistry
        )
        return AppBootstrapCaptureSharingBundle(
            capturePreviewService: resolvedCapturePreviewService,
            catalogService: catalogService,
            captureRegistry: captureRegistry,
            sharingService: resolvedSharingService
        )
    }

    private static func makeSharingService(
        persistence: AppBootstrapPersistenceBundle,
        relayProcessController: RelayProcessController,
        captureRegistry: DisplayCaptureRegistry
    ) -> any SharingServiceProtocol {
        let idStore = DisplayShareIDStore(storeURL: persistence.context.displayShareIDMappingsURL)
        let sharingCoordinator = DisplaySharingCoordinator(
            idStore: idStore,
            acquireShare: { display, invalidationContext in
                try await captureRegistry.acquireShare(
                    display: SendableDisplay(display),
                    invalidationContext: invalidationContext
                )
            }
        )
        return SharingService(
            webServiceController: WebServiceController(relayProcessController: relayProcessController),
            sharingCoordinator: sharingCoordinator
        )
    }
}
