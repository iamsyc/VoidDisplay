import VoidDisplayRuntime

@MainActor
struct AppBootstrapRuntimeBundle {
    let displayRuntime: DisplayRuntime
    let sharingAdapter: DisplayRuntimeSharingAdapter
}

extension AppBootstrap {
    static func makeRuntimeBundle(
        controllers: AppBootstrapBaseControllerBundle,
        captureSharing: AppBootstrapCaptureSharingBundle,
        virtualDisplay: AppBootstrapVirtualDisplayBundle,
        persistence: AppBootstrapPersistenceBundle
    ) -> AppBootstrapRuntimeBundle {
        let catalogAdapter = DisplayRuntimeCatalogAdapter(service: captureSharing.catalogService)
        let captureAdapter = DisplayRuntimeCaptureAdapter(
            controller: controllers.capture,
            sharingController: controllers.sharing,
            isManagedVirtualDisplay: { displayID in
                virtualDisplay.facade.snapshot.managedDisplays.contains {
                    $0.displayID == displayID && $0.isLiveRuntime
                }
            }
        )
        let sharingAdapter = DisplayRuntimeSharingAdapter(
            controller: controllers.sharing,
            capturePerformancePreferences: persistence.capturePerformancePreferences
        )
        let virtualDisplayAdapter = DisplayRuntimeVirtualDisplayAdapter(commandFacade: virtualDisplay.facade)
        let observabilityAdapter = DisplayRuntimeObservabilityAdapter(
            observability: persistence.observability
        )
        let displayRuntime = DisplayRuntime(
            catalogProvider: catalogAdapter,
            captureProvider: captureAdapter,
            sharingProvider: sharingAdapter,
            virtualDisplayProvider: virtualDisplayAdapter,
            catalogCommander: catalogAdapter,
            sharingCommander: sharingAdapter,
            captureIntentCommander: captureAdapter,
            virtualDisplayCommander: virtualDisplayAdapter,
            startupRestoreCommander: virtualDisplayAdapter,
            observabilityRecorder: observabilityAdapter
        )
        return AppBootstrapRuntimeBundle(
            displayRuntime: displayRuntime,
            sharingAdapter: sharingAdapter
        )
    }
}
