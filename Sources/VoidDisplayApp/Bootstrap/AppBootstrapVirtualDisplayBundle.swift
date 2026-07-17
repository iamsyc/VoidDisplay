import VoidDisplayCGVirtualDisplay
import VoidDisplayFoundation
import VoidDisplayVirtualDisplay

@MainActor
struct AppBootstrapVirtualDisplayBundle {
    let facade: any VirtualDisplayFacade
}

extension AppBootstrap {
    static func makeVirtualDisplayBundle(
        facade: (any VirtualDisplayFacade)?,
        persistenceContext: PersistenceContext,
        startupPlan: StartupPlan
    ) -> AppBootstrapVirtualDisplayBundle {
        let resolvedFacade = facade ?? makeVirtualDisplayFacade(persistenceContext: persistenceContext)
        if startupPlan.shouldRestoreVirtualDisplays {
            _ = resolvedFacade.loadPersistedVirtualDisplayConfigsForStartupRestoreCommand()
        }
        return AppBootstrapVirtualDisplayBundle(facade: resolvedFacade)
    }

    private static func makeVirtualDisplayFacade(
        persistenceContext: PersistenceContext
    ) -> any VirtualDisplayFacade {
        let store = VirtualDisplayStore(
            storeURL: persistenceContext.virtualDisplayConfigsURL,
            mode: persistenceContext.mode
        )
        return VirtualDisplayOrchestrator(
            configRepository: VirtualDisplayConfigRepository(store: store),
            runtimeDriver: makeVirtualDisplayRuntimeDriver()
        )
    }
}
